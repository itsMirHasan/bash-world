#!/bin/sh
set -e

# ── Configuration ────────────────────────────────────────────────
PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
PG_SYSTEM_USER="postgres"              # OS user that runs psql without password

DO_SPACES_KEY="${DO_SPACES_KEY}"
DO_SPACES_SECRET="${DO_SPACES_SECRET}"
DO_SPACES_BUCKET="${DO_SPACES_BUCKET}"
DO_SPACES_REGION="${DO_SPACES_REGION:-nyc3}"
DO_SPACES_PATH="${DO_SPACES_PATH:-postgres-backups}"

BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-95}"
BACKUP_DIR="/tmp"

# Databases to skip
SKIP_DBS="postgres template0 template1"
# ─────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────

if [ -z "$DO_SPACES_KEY" ] || [ -z "$DO_SPACES_SECRET" ] || [ -z "$DO_SPACES_BUCKET" ]; then
  echo "[ERROR] DO_SPACES_KEY, DO_SPACES_SECRET, and DO_SPACES_BUCKET must be set."
  exit 1
fi

DATE=$(date +"%Y-%m-%d_%H-%M-%S")

# ── Auto-discover all databases (Unix socket = no password) ───────
echo "[$(date)] Fetching database list..."

DB_LIST=$(su - postgres -c "psql -t -A \
  -c \"SELECT datname FROM pg_database WHERE datistemplate = false;\"")

echo "[$(date)] Found: $(echo $DB_LIST | tr '\n' ' ')"

# ── Loop and backup each database ────────────────────────────────
for DB in $DB_LIST; do

  # Skip system databases
  SKIP=0
  for S in $SKIP_DBS; do
    [ "$DB" = "$S" ] && SKIP=1 && break
  done
  [ "$SKIP" = "1" ] && echo "[$(date)] Skipping: ${DB}" && continue

  BACKUP_FILE="${BACKUP_DIR}/${DB}_${DATE}.sql.gz"
  S3_PATH="s3://${DO_SPACES_BUCKET}/${DO_SPACES_PATH}/${DB}/${DB}_${DATE}.sql.gz"

  echo "[$(date)] Backing up: ${DB}..."

  su - postgres -c "pg_dump \
    -d ${DB} \
    --format=plain \
    --clean \
    --if-exists" | gzip > "${BACKUP_FILE}"

  echo "[$(date)] Dump complete → $(du -sh "$BACKUP_FILE" | cut -f1)"

  # ── Upload to DigitalOcean Spaces ─────────────────────────────
  echo "[$(date)] Uploading → ${S3_PATH}"

  s3cmd put "${BACKUP_FILE}" "${S3_PATH}" \
    --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
    --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
    --access_key="${DO_SPACES_KEY}" \
    --secret_key="${DO_SPACES_SECRET}" \
    --storage-class=STANDARD

  echo "[$(date)] Uploaded → ${S3_PATH}"

  rm -f "${BACKUP_FILE}"
  echo "[$(date)] Done: ${DB}"
  echo "---"

done

# ── Prune old backups per database folder ────────────────────────
if [ -n "${BACKUP_KEEP_DAYS}" ]; then
  CUTOFF=$(date -d "-${BACKUP_KEEP_DAYS} days" +"%Y-%m-%d" 2>/dev/null || date -v-"${BACKUP_KEEP_DAYS}"d +"%Y-%m-%d")

  echo "[$(date)] Pruning backups older than ${CUTOFF} (keeping last ${BACKUP_KEEP_DAYS} days)..."

  for DB in $DB_LIST; do
    SKIP=0
    for S in $SKIP_DBS; do
      [ "$DB" = "$S" ] && SKIP=1 && break
    done
    [ "$SKIP" = "1" ] && continue

    s3cmd ls "s3://${DO_SPACES_BUCKET}/${DO_SPACES_PATH}/${DB}/" \
      --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
      --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
      --access_key="${DO_SPACES_KEY}" \
      --secret_key="${DO_SPACES_SECRET}" 2>/dev/null | \
      awk '{print $4}' | \
      while read -r full_path; do
        key=$(basename "$full_path")
        FILE_DATE=$(echo "$key" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
        if [ -n "$FILE_DATE" ] && [ "$FILE_DATE" \< "$CUTOFF" ]; then
          s3cmd del "s3://${DO_SPACES_BUCKET}/${DO_SPACES_PATH}/${DB}/${key}" \
            --host="${DO_SPACES_REGION}.digitaloceanspaces.com" \
            --host-bucket="%(bucket)s.${DO_SPACES_REGION}.digitaloceanspaces.com" \
            --access_key="${DO_SPACES_KEY}" \
            --secret_key="${DO_SPACES_SECRET}"
          echo "[$(date)] Deleted: ${DB}/${key}"
        fi
      done
  done
fi

echo "[$(date)] All databases backed up successfully."
