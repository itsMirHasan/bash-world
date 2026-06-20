#!/bin/sh
set -e

# ── Configuration ────────────────────────────────────────────────
MYSQL_HOST="${MYSQL_HOST:-db}"
MYSQL_DATABASE="${MYSQL_DATABASE:-d_passbolt}"
MYSQL_USER="${MYSQL_USER:-u_passbolt}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-xxxxxxxxxx}"

DO_SPACES_KEY="${DO_SPACES_KEY}"
DO_SPACES_SECRET="${DO_SPACES_SECRET}"
DO_SPACES_BUCKET="${DO_SPACES_BUCKET}"          # e.g. my-backups
DO_SPACES_REGION="${DO_SPACES_REGION:-nyc3}"    # e.g. fra1, nyc3, ams3



BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-30}"
BACKUP_DIR="/tmp"

PASSBOLT_CONTAINER="${PASSBOLT_CONTAINER:-xxxxxxxxx}"
COMPOSE_DIR="${COMPOSE_DIR:-$(pwd)}"
# ─────────────────────────────────────────────────────────────────

# Validate required secrets
if [ -z "$DO_SPACES_KEY" ] || [ -z "$DO_SPACES_SECRET" ] || [ -z "$DO_SPACES_BUCKET" ]; then
  echo "[ERROR] DO_SPACES_KEY, DO_SPACES_SECRET, and DO_SPACES_BUCKET must be set."
  exit 1
fi

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
WORK_DIR="${BACKUP_DIR}/passbolt_${DATE}"          # staging directory
ARCHIVE="${BACKUP_DIR}/passbolt_full_${DATE}.tar.gz"
S3_ENDPOINT="https://${DO_SPACES_REGION}.digitaloceanspaces.com"
S3_PATH="s3://${DO_SPACES_BUCKET}/passbolt-backups/passbolt_full_${DATE}.tar.gz"

mkdir -p "${WORK_DIR}"
echo "[$(date)] Starting full backup of Passbolt..."

# ── 1. Database dump ──────────────────────────────────────────────
echo "[$(date)] Dumping database '${MYSQL_DATABASE}'..."
mkdir -p "${WORK_DIR}/db"

mysqldump \
  -h "${MYSQL_HOST}" \
  -u "${MYSQL_USER}" \
  -p"${MYSQL_PASSWORD}" \
  --single-transaction \
  --routines \
  --triggers \
  "${MYSQL_DATABASE}" | gzip > "${WORK_DIR}/db/passbolt.sql.gz"

echo "[$(date)] Database dump complete ($(du -sh "${WORK_DIR}/db/passbolt.sql.gz" | cut -f1))"

# ── 2. GPG keys ───────────────────────────────────────────────────
echo "[$(date)] Copying GPG keys..."
mkdir -p "${WORK_DIR}/gpg"

docker cp "${PASSBOLT_CONTAINER}:/etc/passbolt/gpg/serverkey.asc"         "${WORK_DIR}/gpg/" 2>/dev/null || true
docker cp "${PASSBOLT_CONTAINER}:/etc/passbolt/gpg/serverkey_private.asc" "${WORK_DIR}/gpg/" 2>/dev/null || true

echo "[$(date)] GPG keys copied."

# ── 3. JWT keys ───────────────────────────────────────────────────
echo "[$(date)] Copying JWT keys..."
mkdir -p "${WORK_DIR}/jwt"

docker cp "${PASSBOLT_CONTAINER}:/etc/passbolt/jwt/jwt.key" "${WORK_DIR}/jwt/" 2>/dev/null || true
docker cp "${PASSBOLT_CONTAINER}:/etc/passbolt/jwt/jwt.pem" "${WORK_DIR}/jwt/" 2>/dev/null || true

echo "[$(date)] JWT keys copied."

# ── 4. Passbolt config ────────────────────────────────────────────
echo "[$(date)] Copying passbolt.php config..."
mkdir -p "${WORK_DIR}/config"

docker cp "${PASSBOLT_CONTAINER}:/etc/passbolt/passbolt.php" "${WORK_DIR}/config/" 2>/dev/null || true

echo "[$(date)] Config copied."

# ── 5. docker-compose.yml + .env ─────────────────────────────────
echo "[$(date)] Copying compose files..."
mkdir -p "${WORK_DIR}/compose"

[ -f "${COMPOSE_DIR}/docker-compose.yml" ] && cp "${COMPOSE_DIR}/docker-compose.yml" "${WORK_DIR}/compose/"
[ -f "${COMPOSE_DIR}/.env" ]               && cp "${COMPOSE_DIR}/.env"               "${WORK_DIR}/compose/"

echo "[$(date)] Compose files copied."

# ── 6. Pack everything into one archive ──────────────────────────
echo "[$(date)] Creating archive..."
tar -czf "${ARCHIVE}" -C "${BACKUP_DIR}" "passbolt_${DATE}"
echo "[$(date)] Archive ready: ${ARCHIVE} ($(du -sh "${ARCHIVE}" | cut -f1))"

# ── 7. Upload to DigitalOcean Spaces ─────────────────────────────
echo "[$(date)] Uploading to Spaces → ${S3_PATH}"

s3cmd put "${ARCHIVE}" "${S3_PATH}" \
  --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
  --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
  --access_key="${DO_SPACES_KEY}" \
  --secret_key="${DO_SPACES_SECRET}" \
  --storage-class=STANDARD

echo "[$(date)] Upload complete → ${S3_PATH}"

# ── 8. Cleanup local files ────────────────────────────────────────
rm -rf "${WORK_DIR}" "${ARCHIVE}"
echo "[$(date)] Local temp files removed."



# ── 9. Prune old backups from Spaces ─────────────────────────────
if [ -n "${BACKUP_KEEP_DAYS}" ]; then
  CUTOFF=$(date -d "-${BACKUP_KEEP_DAYS} days" +"%Y-%m-%d" 2>/dev/null) || \
  CUTOFF=$(date -v-"${BACKUP_KEEP_DAYS}"d +"%Y-%m-%d")

  echo "[$(date)] Pruning backups older than ${CUTOFF} (keeping last ${BACKUP_KEEP_DAYS} days)..."

  s3cmd ls "s3://${DO_SPACES_BUCKET}/passbolt-backups/" \
    --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
    --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
    --access_key="${DO_SPACES_KEY}" \
    --secret_key="${DO_SPACES_SECRET}" | \
    awk '{print $4}' | \
    while read -r full_path; do
      key=$(basename "$full_path")
      FILE_DATE=$(echo "$key" | cut -c1-10)
      if [ "$FILE_DATE" \< "$CUTOFF" ]; then
        s3cmd del "s3://${DO_SPACES_BUCKET}/passbolt-backups/${key}" \
          --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
          --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
          --access_key="${DO_SPACES_KEY}" \
          --secret_key="${DO_SPACES_SECRET}"
        echo "[$(date)] Deleted old backup: ${key}"
      fi
    done
fi

echo "[$(date)] Backup job finished successfully."
