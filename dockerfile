# ===============================
#  Dockerfile - Nextcloud (sans post-install)
#  Ubuntu 24.04 + Apache2 + PHP 8.3 (+ MariaDB locale optionnelle)
# ===============================

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

# Utiliser bash pour plus de robustesse
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---- Paquets système, Apache, MariaDB, PHP & extensions Nextcloud ----
RUN apt-get update && apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
      apache2 mariadb-server wget curl ca-certificates unzip \
      php libapache2-mod-php php-mysql php-xml php-curl php-gd php-zip \
      php-mbstring php-intl php-bcmath php-gmp php-imagick php-exif php-apcu \
      util-linux procps sudo ffmpeg smbclient && \
    update-ca-certificates && rm -rf /var/lib/apt/lists/*

# ---- Télécharger Nextcloud (dernière archive stable) ----
WORKDIR /tmp
RUN wget -q https://download.nextcloud.com/server/releases/latest.zip && \
    mkdir -p /var/www/html && \
    unzip -q latest.zip && \
    # déplace le contenu de nextcloud/ vers /var/www/html/
    rsync -a nextcloud/ /var/www/html/ && \
    rm -rf latest.zip nextcloud

# ---- Apache: modules + vhost Nextcloud ----
RUN a2enmod rewrite headers env dir mime setenvif && \
    rm -f /etc/apache2/sites-enabled/000-default.conf

# Nextcloud s’appuie sur .htaccess => AllowOverride All sur le docroot
RUN cat >/etc/apache2/sites-available/nextcloud.conf <<'__VHOST__'
<VirtualHost *:80>
    ServerName _
    DocumentRoot /var/www/html
    DirectoryIndex index.php

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

    # En-têtes recommandées
    <IfModule mod_headers.c>
        Header always set Referrer-Policy "no-referrer"
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-XSS-Protection "1; mode=block"
        Header always set Permissions-Policy "interest-cohort=()"
    </IfModule>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
__VHOST__
RUN a2ensite nextcloud

# ---- PHP tuning (valeurs recommandées Nextcloud) ----
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

# ---- Permissions web ----
RUN chown -R www-data:www-data /var/www/html && \
    find /var/www/html -type d -exec chmod 750 {} \; && \
    find /var/www/html -type f -exec chmod 640 {} \;

# ---------- Script d'entrée (sans post-install) ----------
# - Initialise MariaDB si le datadir est vide
# - Démarre MariaDB en arrière-plan (optionnel)
# - (Optionnel) crée la base 'nextcloud' et l'utilisateur 'nextcloud' (aucun occ lancé)
# - Lance Apache au premier plan (OK pour Dokploy)
RUN cat >/usr/local/bin/entrypoint.sh <<'__ENTRY__'
#!/usr/bin/env bash
set -Eeuo pipefail

echo "==[BOOT]== $(date -Is) Nextcloud container (no post-install)"

# Répertoires runtime
mkdir -p /run/mysqld /run/apache2
chown -R mysql:mysql /run/mysqld /var/lib/mysql || true

# MariaDB locale optionnelle
if command -v mariadb-install-db >/dev/null 2>&1; then
  if [ ! -d "/var/lib/mysql/mysql" ]; then
    echo "==[DB]== Initialisation MariaDB (datadir vide)"
    mariadb-install-db --user=mysql --ldata=/var/lib/mysql
  fi

  echo "==[DB]== Démarrage MariaDB"
  mysqld_safe --skip-networking=0 --bind-address=127.0.0.1 >/var/log/mysqld_safe.log 2>&1 &
  for i in $(seq 1 60); do
    mysqladmin ping -uroot --silent && break || sleep 1
  done

  # Création OPTIONNELLE base & user (sans post-install Nextcloud)
  if mysql -uroot -e "SELECT 1" >/dev/null 2>&1; then
    mysql -uroot <<'__SQL__'
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY 'P@ssw0rd';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
__SQL__
    echo "==[DB]== Base 'nextcloud' et user 'nextcloud' prêts (aucune post-install Nextcloud exécutée)"
  fi
else
  echo "==[DB]== MariaDB non présent, on continue sans base locale"
fi

# Démarrage Apache au premier plan (Dokploy OK)
echo "==[WEB]== Démarrage Apache (foreground)"
exec apache2ctl -D FOREGROUND
__ENTRY__
RUN chmod +x /usr/local/bin/entrypoint.sh

# ---- Exposition & santé ----
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=10 \
  CMD curl -fsS -o /dev/null http://127.0.0.1/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
