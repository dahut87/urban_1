#!/usr/bin/env bash
set -euo pipefail

# =========================
# Configuration
# =========================
APP_NAME="${APP_NAME:-urbanhub}"
REPO_URL="${REPO_URL:-https://gitea.newkube.ia86.cc/Nicolas_Horde/Formation_Cloud_devoir1.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

# Chemins attendus dans le dépôt
REPO_SQL_PATH="${REPO_SQL_PATH:-init.sql}"
REPO_PHP_PATH="${REPO_PHP_PATH:-php}"

# Paramètres BDD applicative
APP_DB_NAME="${APP_DB_NAME:-urbanhub}"
APP_DB_USER="${APP_DB_USER:-urbanhub_app}"

# Identifiants master RDS
MASTER_DB_USER="${MASTER_DB_USER:?MASTER_DB_USER must be set}"
MASTER_DB_PASSWORD="${MASTER_DB_PASSWORD:?MASTER_DB_PASSWORD must be set}"

# Région AWS
AWS_REGION="${AWS_REGION:-}"
APP_DIR="/var/www/${APP_NAME}"
WEB_ROOT="${APP_DIR}/public"
SQL_IMPORT_MARKER="${APP_DIR}/.sql_import_done"

export DEBIAN_FRONTEND=noninteractive

log() {
  echo "[$(date '+%F %T')] $*"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

ensure_packages() {
  local missing=()

  for pkg in "$@"; do
    if ! pkg_installed "$pkg"; then
      missing+=("$pkg")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    log "Installation des paquets manquants: ${missing[*]}"
    sudo apt update
    sudo apt install -y "${missing[@]}"
  else
    log "Paquets déjà présents"
  fi
}

# =========================
# Paquets système
# =========================
ensure_packages \
  apache2 \
  php \
  libapache2-mod-php \
  php-mysql \
  mariadb-client \
  git \
  curl \
  unzip \
  jq \
  openssl \
  rsync

# =========================
# AWS CLI v2
# =========================
if has_cmd aws; then
  log "AWS CLI déjà installé : $(aws --version 2>&1)"
else
  log "Installation AWS CLI v2 (manuel)"
  TMP_DIR="/tmp/awscli-install"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  cd "$TMP_DIR"

  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  sudo ./aws/install --update

  log "AWS CLI installé : $(aws --version 2>&1)"
  cd /
  rm -rf "$TMP_DIR"
fi

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

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
RDS_INSTANCE_ID="$(aws rds describe-db-instances \
  --region "${AWS_REGION}" \
  --query "DBInstances[?DBInstanceStatus=='available'].[DBInstanceIdentifier]" \
  --output text | awk 'NF {print $1; exit}')"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-eu-west-3}}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# =========================
# Vérification credentials AWS
# =========================
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS CLI installé, mais aucune credential IAM n'est disponible." >&2
  echo "Vérifier le rôle IAM attaché à l'instance EC2 / Launch Template." >&2
  exit 1
fi

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
if [[ -f "${APP_DIR}/.app_db_password" ]]; then
  APP_DB_PASSWORD="$(sudo cat "${APP_DIR}/.app_db_password")"
  log "Mot de passe applicatif réutilisé"
else
  APP_DB_PASSWORD="$(openssl rand -base64 24 | tr -d '\n' | tr '/+' 'AZ')"
  sudo mkdir -p "${APP_DIR}"
  printf '%s' "${APP_DB_PASSWORD}" | sudo tee "${APP_DIR}/.app_db_password" >/dev/null
  sudo chmod 600 "${APP_DIR}/.app_db_password"
  log "Mot de passe applicatif généré"
fi

# =========================
# Préparation dépôt
# =========================
sudo git config --system --add safe.directory "${APP_DIR}" || true
if [[ -d "${APP_DIR}/.git" ]]; then
  log "Dépôt déjà présent, mise à jour"
  sudo git -C "${APP_DIR}" fetch --all --prune
  sudo git -C "${APP_DIR}" reset --hard "origin/${REPO_BRANCH}"
else
  log "Clonage du dépôt"
  sudo rm -rf "${APP_DIR}"
  sudo mkdir -p "${APP_DIR}"
  sudo git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${APP_DIR}"
fi

SQL_FILE="${APP_DIR}/${REPO_SQL_PATH}"
PHP_SOURCE_DIR="${APP_DIR}/${REPO_PHP_PATH}"

if [[ ! -f "${SQL_FILE}" ]]; then
  echo "Fichier SQL introuvable : ${SQL_FILE}" >&2
  exit 1
fi

if [[ ! -d "${PHP_SOURCE_DIR}" ]]; then
  echo "Dossier PHP introuvable : ${PHP_SOURCE_DIR}" >&2
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
# Création du user applicatif
# =========================
log "Création / mise à jour du compte applicatif MariaDB"
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
if [[ -f "${SQL_IMPORT_MARKER}" ]]; then
  log "Import SQL déjà effectué, étape ignorée"
else
  log "Import du fichier SQL du dépôt : ${SQL_FILE}"
  mysql -h "${DB_HOST}" -u "${APP_DB_USER}" -p"${APP_DB_PASSWORD}" < "${SQL_FILE}"
  sudo touch "${SQL_IMPORT_MARKER}"
  sudo chmod 600 "${SQL_IMPORT_MARKER}"
fi

# =========================
# Déploiement du dossier PHP
# =========================
log "Déploiement du dossier PHP complet"
sudo mkdir -p "${WEB_ROOT}"
sudo rsync -a --delete "${PHP_SOURCE_DIR}/" "${WEB_ROOT}/"

# =========================
# Fichier de configuration pour l'application PHP
# =========================
sudo tee "${APP_DIR}/.env" >/dev/null <<EOF
APP_NAME=${APP_NAME}
DB_HOST=${DB_HOST}
DB_NAME=${APP_DB_NAME}
DB_USER=${APP_DB_USER}
DB_PASSWORD=${APP_DB_PASSWORD}
AWS_REGION=${AWS_REGION}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
AWS_RDS_INSTANCE_ID=${RDS_INSTANCE_ID}
INSTANCE_HOSTNAME=$(hostname)
EOF

log "Installation des certificats SSL"
sudo mkdir -p /etc/ssl/rds
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem -o /tmp/global-bundle.pem
sudo mv /tmp/global-bundle.pem /etc/ssl/rds/global-bundle.pem
sudo chmod 644 /etc/ssl/rds/global-bundle.pem

sudo chown -R www-data:www-data "${APP_DIR}"
sudo find "${APP_DIR}" -type d -exec chmod 755 {} \;
sudo find "${APP_DIR}" -type f -exec chmod 644 {} \;
sudo chmod 600 "${APP_DIR}/.env"
sudo chmod 600 "${APP_DIR}/.app_db_password" "${SQL_IMPORT_MARKER}" 2>/dev/null || true

# =========================
# Apache
# =========================
APACHE_CONF="/etc/apache2/sites-available/${APP_NAME}.conf"

log "Configuration Apache"
sudo tee "${APACHE_CONF}" >/dev/null <<EOF
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

if sudo test -L /etc/apache2/sites-enabled/000-default.conf; then
  sudo a2dissite 000-default.conf || true
fi

if ! sudo test -L "/etc/apache2/sites-enabled/${APP_NAME}.conf"; then
  sudo a2ensite "${APP_NAME}.conf"
fi

if ! sudo apache2ctl -M 2>/dev/null | grep -q 'rewrite_module'; then
  sudo a2enmod rewrite
fi

sudo systemctl enable apache2
sudo systemctl restart apache2

# =========================
# Trace locale utile au debug
# =========================
sudo tee /root/${APP_NAME}_deployment_info.txt >/dev/null <<EOF
APP_NAME=${APP_NAME}
AWS_REGION=${AWS_REGION}
RDS_HOST=${DB_HOST}
APP_DB_NAME=${APP_DB_NAME}
APP_DB_USER=${APP_DB_USER}
APP_DB_PASSWORD=${APP_DB_PASSWORD}
REPO_URL=${REPO_URL}
REPO_BRANCH=${REPO_BRANCH}
SQL_FILE=${SQL_FILE}
PHP_SOURCE_DIR=${PHP_SOURCE_DIR}
WEB_ROOT=${WEB_ROOT}
EOF
sudo chmod 600 /root/${APP_NAME}_deployment_info.txt

log "Déploiement terminé"
log "RDS_HOST=${DB_HOST}"
log "APP_DB_NAME=${APP_DB_NAME}"
log "APP_DB_USER=${APP_DB_USER}"
log "DocumentRoot=${WEB_ROOT}"
