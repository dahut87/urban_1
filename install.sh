#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration
# =========================
APP_NAME="${APP_NAME:-urbanhub}"
REPO_URL="${REPO_URL:-https://gitea.newkube.ia86.cc/Nicolas_Horde/Formation_Cloud_devoir1.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# Chemins attendus dans le dépôt
REPO_SQL_PATH="${REPO_SQL_PATH:-sql/init.sql}"
REPO_PHP_PATH="${REPO_PHP_PATH:-php/index.php}"

# Paramètres BDD applicative
APP_DB_NAME="${APP_DB_NAME:-urbanhub}"
APP_DB_USER="${APP_DB_USER:-urbanhub_app}"

# Identifiants master RDS (à fournir via user data / variables / secret)
MASTER_DB_USER="${MASTER_DB_USER:?MASTER_DB_USER must be set}"
MASTER_DB_PASSWORD="${MASTER_DB_PASSWORD:?MASTER_DB_PASSWORD must be set}"

# Région AWS (déduite via IMDSv2 sinon AWS_DEFAULT_REGION sinon eu-west-3)
AWS_REGION="${AWS_REGION:-}"
APP_DIR="/var/www/${APP_NAME}"
WEB_ROOT="${APP_DIR}/public"

export DEBIAN_FRONTEND=noninteractive

log() {
  echo "[$(date '+%F %T')] $*"
}

# =========================
# Détection région AWS
# =========================
if [[ -z "${AWS_REGION}" ]]; then
  TOKEN="$(curl -s -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
  if [[ -n "${TOKEN}" ]]; then
    IID_DOC="$(curl -s -m 3 -H "X-aws-ec2-metadata-token: ${TOKEN}" \
      http://169.254.169.254/latest/dynamic/instance-identity/document || true)"
    AWS_REGION="$(printf '%s' "${IID_DOC}" | awk -F\" '/region/ {print $4; exit}')"
  fi
fi

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-3}}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# =========================
# Installation paquets
# =========================
log "Installation des paquets"
apt update
apt install -y \
  apache2 \
  php \
  libapache2-mod-php \
  php-mysql \
  mariadb-client \
  git \
  curl \
  unzip \
  jq \
  awscli \
  openssl

# =========================
# Recherche du premier endpoint RDS disponible
# =========================
log "Recherche de la première instance RDS disponible dans ${AWS_REGION}"
DB_HOST="$(
  aws rds describe-db-instances \
    --region "${AWS_REGION}" \
    --query "DBInstances[?DBInstanceStatus=='available' && Endpoint.Address!=null].[Endpoint.Address]" \
    --output text | awk 'NF {print $1; exit}'
)"

if [[ -z "${DB_HOST}" || "${DB_HOST}" == "None" ]]; then
  echo "Aucune instance RDS disponible trouvée dans ${AWS_REGION}" >&2
  exit 1
fi

log "Endpoint RDS sélectionné : ${DB_HOST}"

# =========================
# Mot de passe random pour l'utilisateur applicatif
# =========================
APP_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AZ')"
log "Mot de passe applicatif généré"

# =========================
# Préparation dépôt
# =========================
log "Clonage du dépôt"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}"
git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${APP_DIR}"

SQL_FILE="${APP_DIR}/${REPO_SQL_PATH}"
PHP_FILE="${APP_DIR}/${REPO_PHP_PATH}"

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Fichier SQL introuvable : ${SQL_FILE}" >&2
  exit 1
fi

if [[ ! -f "${PHP_FILE}" ]]; then
  echo "Fichier PHP introuvable : ${PHP_FILE}" >&2
  exit 1
fi

# =========================
# Attente de disponibilité MariaDB
# =========================
log "Attente de disponibilité de MariaDB sur ${DB_HOST}"
until mysqladmin ping \
  -h "${DB_HOST}" \
  -u "${MASTER_DB_USER}" \
  -p"${MASTER_DB_PASSWORD}" \
  --silent
do
  sleep 5
done

# =========================
# Création BDD + user applicatif
# =========================
log "Création de la base et de l'utilisateur applicatif"
mysql -h "${DB_HOST}" -u "${MASTER_DB_USER}" -p"${MASTER_DB_PASSWORD}" <<EOF
CREATE DATABASE IF NOT EXISTS \`${APP_DB_NAME}\`
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASSWORD}';
ALTER USER '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${APP_DB_NAME}\`.* TO '${APP_DB_USER}'@'%';
FLUSH PRIVILEGES;
EOF

# =========================
# Import du SQL du dépôt
# =========================
log "Préparation du fichier SQL pour import"
TMP_SQL="/tmp/${APP_NAME}_init.sql"

{
  printf 'CREATE DATABASE IF NOT EXISTS `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\n' "${APP_DB_NAME}"
  printf 'USE `%s`;\n' "${APP_DB_NAME}"
  cat "${SQL_FILE}"
} > "${TMP_SQL}"

log "Import du SQL"
mysql -h "${DB_HOST}" -u "${MASTER_DB_USER}" -p"${MASTER_DB_PASSWORD}" < "${TMP_SQL}"

# =========================
# Déploiement PHP
# =========================
log "Déploiement du PHP"
mkdir -p "${WEB_ROOT}"
cp "${PHP_FILE}" "${WEB_ROOT}/index.php"

# Healthcheck ALB
cat > "${WEB_ROOT}/health.php" <<'EOF'
<?php
http_response_code(200);
header('Content-Type: text/plain; charset=utf-8');
echo "OK";
EOF

# Fichier de config consommé par le PHP
cat > "${APP_DIR}/.env" <<EOF
APP_NAME=${APP_NAME}
DB_HOST=${DB_HOST}
DB_NAME=${APP_DB_NAME}
DB_USER=${APP_DB_USER}
DB_PASSWORD=${APP_DB_PASSWORD}
AWS_REGION=${AWS_REGION}
INSTANCE_HOSTNAME=$(hostname)
EOF

# =========================
# Apache
# =========================
log "Configuration Apache"
cat > /etc/apache2/sites-available/${APP_NAME}.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${APP_NAME}_error.log
    CustomLog \${APACHE_LOG_DIR}/${APP_NAME}_access.log combined
</VirtualHost>
EOF

a2dissite 000-default.conf || true
a2ensite "${APP_NAME}.conf"
a2enmod rewrite
systemctl enable apache2
systemctl restart apache2

# =========================
# Trace locale utile au debug
# =========================
cat > /root/${APP_NAME}_deployment_info.txt <<EOF
APP_NAME=${APP_NAME}
AWS_REGION=${AWS_REGION}
RDS_HOST=${DB_HOST}
APP_DB_NAME=${APP_DB_NAME}
APP_DB_USER=${APP_DB_USER}
APP_DB_PASSWORD=${APP_DB_PASSWORD}
REPO_URL=${REPO_URL}
REPO_BRANCH=${REPO_BRANCH}
SQL_FILE=${SQL_FILE}
PHP_FILE=${PHP_FILE}
EOF
chmod 600 /root/${APP_NAME}_deployment_info.txt

log "Déploiement terminé"
log "RDS_HOST=${DB_HOST}"
log "APP_DB_NAME=${APP_DB_NAME}"
log "APP_DB_USER=${APP_DB_USER}"
log "Healthcheck: /health.php"