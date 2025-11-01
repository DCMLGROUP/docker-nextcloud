# ===============================
#  Dockerfile - Nextcloud (fix des alertes)
#  Ubuntu 24.04 + Apache2 + PHP 8.3 + Redis
#  - PAS de post-install initiale (pas de occ maintenance:install)
#  - Auto-remediation occ SI Nextcloud déjà installé (config.php présent)
#  - PAS de SMTP, PAS de Traefik ici (proxy externe)
# ===============================

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# === Variables d'env (à surcharger dans Dokploy) ===
ENV NC_DOMAIN="nextcloud.example.com" \
    NC_OVERWRITE_PROTO="https" \
    NC_TRUSTED_PROXIES="10.0.0.0/8,172.16.0.0/12,192.168.0.0/16" \
    NC_DEFAULT_PHONE_REGION="FR" \
    NC_MAINT_WINDOW_START="3" \
    NC_DATA_DIR="/var/nc-data"

# Utiliser bash pour RUN
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Paquets système, Apache, MariaDB (optionnel), PHP & extensions Nextcloud, Redis ----
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates unzip rsync \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd php-zip \
      php-mbstring php-intl php-bcmath php-gmp php-imagick php-exif php-apcu \
      redis-server php-redis \
      ghostscript librsvg2-2 \
      util-linux procps sudo ffmpeg smbclient cron && \
    update-ca-certificates && rm -rf /var/lib/apt/lists/*

# ---- Télécharger Nextcloud stable ----
WORKDIR /tmp
RUN wget -q https://download.nextcloud.com/server/releases/latest.zip && \
    mkdir -p /var/www/html && \
    unzip -q latest.zip && \
    rsync -a nextcloud/ /var/www/html/ && \
    rm -rf latest.zip nextcloud

# ---- Apache: modules + vhost Nextcloud (MIME, headers, .well-known) ----
RUN a2enmod rewrite headers env dir mime setenvif && \
    rm -f /etc/apache2/sites-enabled/000-default.conf
RUN cat >/etc/apache2/sites-available/nextcloud.conf <<'__VHOST__'
<VirtualHost *:80>
    ServerName _
    DocumentRoot /var/www/html
    DirectoryIndex index.php

    # ---- Réécritures Nextcloud (.htaccess actif) ----
    <Directory /var/www/html>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
        SetEnv HOME /var/www/html
        SetEnv HTTP_HOME /var/www/html
    </Directory>

    # ---- Redirections .well-known ----
    Redirect 301 /.well-known/carddav  /remote.php/dav
    Redirect 301 /.well-known/caldav   /remote.php/dav

    # ---- Types MIME pour checks Nextcloud ----
    AddType application/javascript .mjs
    AddType application/json       .map
    AddType application/wasm       .wasm
    AddType font/otf               .otf

    # ---- En-têtes sécurité (HSTS appliqué quand reverse-proxy sert en HTTPS) ----
    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains; preload"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set Referrer-Policy "no-referrer"
        Header always set Permissions-Policy "interest-cohort=()"
    </IfModule>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
__VHOST__
RUN a2ensite nextcloud

# ---- PHP tuning (recommandations Nextcloud) ----
RUN mkdir -p /etc/php/8.3/apache2/conf.d
RUN cat >/etc/php/8.3/apache2/conf.d/90-nextcloud.ini <<'__PHPINI__'
; Mémoire & uploads
memory_limit = 512M
upload_max_filesize = 2G
post_max_size = 2G
max_execution_time = 360
output_buffering = Off
; Opcache
opcache.enable=1
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.memory_consumption=192
opcache.save_comments=1
opcache.revalidate_freq=60
; APCu (cache local)
apc.enable_cli=1
apc.shm_size=128M
; Sécurité sessions
session.cookie_httponly = 1
session.use_strict_mode = 1
__PHPINI__

# ---- Data dir hors webroot + droits ----
RUN mkdir -p "${NC_DATA_DIR}" && \
    chown -R www-data:www-data "${NC_DATA_DIR}" && \
    chmod 750 "${NC_DATA_DIR}"
RUN chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 750 {} \; && \
    find /var/www/html -type f -exec chmod 640 {} \;

# ---- Imagick: activer SVG si bloqué par policy.xml ----
RUN if [ -f /etc/ImageMagick-6/policy.xml ]; then \
      sed -i 's~<policy domain="coder" rights="none" pattern="SVG" />~<!-- SVG enabled -->~g' /etc/ImageMagick-6/policy.xml || true ; \
    fi

# ---------- Script d'entrée ----------
# - Démarre Redis
# - (Optionnel) Initialise + démarre MariaDB locale (si présente)
# - Lance une boucle cron interne (*/5 min) pour cron.php
# - SI Nextcloud déjà installé (config.php présent) => applique remédiations `occ`
#   (trusted_domains, overwrite*, trusted_proxies, forwarded_for_headers, memcache, datadirectory,
#    maintenance_window_start, default_phone_region, db:add-missing-indices, maintenance:repair --include-expensive)
# - Démarre Apache (foreground)
RUN cat >/usr/local/bin/entrypoint.sh <<'__ENTRY__'
#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[$(date -Is)] $*"; }

log "== BOOT: Nextcloud container =="

# 1) Redis
log "Starting redis-server"
redis-server --daemonize yes

# 2) MariaDB locale (optionnelle)
if command -v mariadb-install-db >/dev/null 2>&1; then
  mkdir -p /run/mysqld
  chown -R mysql:mysql /run/mysqld /var/lib/mysql || true
  if [ ! -d "/var/lib/mysql/mysql" ]; then
    log "Initializing MariaDB datadir"
    mariadb-install-db --user=mysql --ldata=/var/lib/mysql
  fi
  log "Starting MariaDB"
  mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &
  for i in $(seq 1 60); do
    if mysqladmin ping -uroot --silent; then break; fi
    sleep 1
  done || true

  # Création silencieuse base & user si Nextcloud choisit cette DB locale
  if mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mysql -uroot <<'__SQL__'
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
__SQL__
    log "MariaDB ready (DB nextcloud / user nextcloud@localhost)"
  fi
else
  log "MariaDB not present (external DB expected)"
fi

# 3) Cron interne simple (évite un second conteneur) — toutes les 5 minutes
( while true; do
    sleep 300
    if [ -f /var/www/html/cron.php ]; then
      sudo -u www-data php -f /var/www/html/cron.php >/dev/null 2>&1 || true
    fi
  done ) &

# 4) Auto-remédiation SI Nextcloud déjà installé
NC_CFG="/var/www/html/config/config.php"
if [ -f "$NC_CFG" ]; then
  log "config.php found — applying remediation via occ"

  # Attendre qu'Apache serve PHP correctement avant occ
  # (certains environnements ont besoin que mod_php soit “chaud”)
  sleep 3

  # Helper occ
  OCC='sudo -u www-data php -d memory_limit=1024M /var/www/html/occ'

  # a) Core config (trusted domains, proxy headers, overwrite*)
  $OCC config:system:set trusted_domains 0 --value="${NC_DOMAIN}" --type=string || true
  $OCC config:system:set overwrite.cli.url  --value="${NC_OVERWRITE_PROTO}://${NC_DOMAIN}" --type=string || true
  $OCC config:system:set overwritehost       --value="${NC_DOMAIN}" --type=string || true
  $OCC config:system:set overwriteprotocol   --value="${NC_OVERWRITE_PROTO}" --type=string || true

  # trusted_proxies (liste CSV -> tableau)
  IFS=',' read -ra PRX <<< "${NC_TRUSTED_PROXIES}"
  idx=0
  for p in "${PRX[@]}"; do
    $OCC config:system:set trusted_proxies $idx --value="$p" --type=string || true
    idx=$((idx+1))
  done
  # forwarded_for_headers
  $OCC config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR" --type=string || true
  $OCC config:system:set forwarded_for_headers 1 --value="HTTP_FORWARDED"      --type=string || true

  # b) Data dir (hors webroot) — ne change rien si déjà configuré autrement
  $OCC config:system:set datadirectory --value="${NC_DATA_DIR}" --type=string || true
  mkdir -p "${NC_DATA_DIR}" && chown -R www-data:www-data "${NC_DATA_DIR}" && chmod 750 "${NC_DATA_DIR}"

  # c) Memcache & locks (APCu + Redis local)
  $OCC config:system:set memcache.local   --value="\\OC\\Memcache\\APCu"  --type=string || true
  $OCC config:system:set memcache.locking --value="\\OC\\Memcache\\Redis" --type=string || true
  $OCC config:system:set redis host --value="127.0.0.1" --type=string || true
  $OCC config:system:set redis port --value="6379"      --type=integer || true

  # d) Fenêtre de maintenance & région téléphone
  $OCC config:system:set maintenance_window_start --value="${NC_MAINT_WINDOW_START}" --type=integer || true
  $OCC config:system:set default_phone_region --value="${NC_DEFAULT_PHONE_REGION}" --type=string || true

  # e) Indices & migrations mimetype (peut durer)
  $OCC db:add-missing-indices || true
  $OCC maintenance:repair --include-expensive || true

  # f) Client Push (application) — active l'app si présente
  $OCC app:install client_push || true
  $OCC app:enable  client_push || true

  log "Remediation steps applied (where applicable)."
else
  log "config.php not found — skipping occ remediation (install Nextcloud via web first)."
fi

# 5) Apache en foreground
log "Starting Apache (foreground)"
exec apache2ctl -D FOREGROUND
__ENTRY__
RUN chmod +x /usr/local/bin/entrypoint.sh

# ---- Healthcheck (HTTP interne) ----
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 \
  CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
