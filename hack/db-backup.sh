#!/usr/bin/env bash
set -euo pipefail

# =========================================================
#  Database Backup Script
#  - Backs up PostgreSQL databases running in AKS
#  - Uploads backups to Azure Blob Storage
#  - Generates detailed logs
#  - Creates unique timestamped folders per run
# =========================================================
# Author: Owais Khan
# Date:   2025-11-05

# --- Required Environment Variables (from GitHub Actions) ---
# TARGET_CONTEXT     = Kubernetes context name
# NAMESPACE          = Kubernetes namespace
# AZURE_ACCOUNT      = Azure storage account name
# AZURE_CONTAINER    = Azure blob container name

# --- Print starting info ---
echo "----------------------------------------"
echo "Starting database backup at $(date)"
echo "Cluster context: $TARGET_CONTEXT"
echo "Namespace:       $NAMESPACE"
echo "Azure Account:   $AZURE_ACCOUNT"
echo "Azure Container: $AZURE_CONTAINER"
echo "----------------------------------------"

# --- Switch to the correct cluster context ---
echo "Switching Kubernetes context..."
kubectl config use-context "$TARGET_CONTEXT"
sleep 5
echo "Current context: $(kubectl config current-context)"
echo "----------------------------------------"

# --- Prepare timestamped directories ---
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_DIR="./backup/backup_$TIMESTAMP"
LOG_DIR="./logs/backup_$TIMESTAMP"

mkdir -p "$BACKUP_DIR" "$LOG_DIR"

# --- Initialize log file ---
LOG_FILE="$LOG_DIR/backup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Backup folder: $BACKUP_DIR"
echo "Log folder: $LOG_DIR"
echo "----------------------------------------"

# --- Databases to back up ---
DBS=(
  "sharedidp-postgresql:fed-services-sharedidp-postgresql-0:kcshared:dbpasswordshared!dp:iamsharedidp"
  "postgresql:fed-services-postgresql-0:issuer:dbpasswordissuer:issuer"
  "portal-backend:fed-services-portal-backend-postgresql-0:postgres:dbpasswordportal:postgres"
  "issuer-postgresql:fed-services-issuer-postgresql-0:issuer:dbpasswordissuer:issuer"
  "discoveryfinder:fed-services-discoveryfinder-postgresql-0:catenax:dbpassworddiscv0eryf!nder:discoveryfinder"
  "dataconsumer-1-db:fed-services-dataconsumer-1-db-0:testuser:dbpassworddataconsumerone:edc"
  "centralidp-postgresql:fed-services-centralidp-postgresql-0:kccentral:dbpasswordcentralidp:iamcentralidp"
  "bpndiscovery-postgresql:fed-services-bpndiscovery-postgresql-0:default-user:dbpasswordbpnd!sc0very:bpndiscovery"
)

# --- Step 1: Take backups ---
echo "Step 1: Taking backups..."
for ENTRY in "${DBS[@]}"; do
  IFS=":" read -r DB_NAME POD USER PASSWORD DATABASE <<< "$ENTRY"
  BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_full_backup.sql"

  echo "Backing up $DB_NAME from pod $POD..."
  if [[ -z "$USER" || -z "$PASSWORD" || -z "$DATABASE" ]]; then
    echo "Skipping $DB_NAME: missing credentials"
    continue
  fi

  if kubectl exec -n "$NAMESPACE" -i "$POD" -- \
    sh -c "PGPASSWORD='$PASSWORD' pg_dump -U $USER -d $DATABASE --no-owner --clean" > "$BACKUP_FILE"; then
    echo "Backup saved to $BACKUP_FILE"
  else
    echo "Backup FAILED for $DB_NAME"
    rm -f "$BACKUP_FILE"
  fi
  echo "----------------------------------------"
done

# --- Step 2: Verify backups ---
echo "Step 2: Verifying backup files..."
for FILE in "$BACKUP_DIR"/*.sql; do
  if [[ -f "$FILE" && -s "$FILE" ]]; then
    echo "Found backup: $FILE ($(du -h "$FILE" | cut -f1))"
  else
    echo "Missing or empty backup file: $FILE"
  fi
done
echo "----------------------------------------"

# --- Step 3: Upload to Azure Blob ---
echo "Step 3: Uploading backups to Azure Blob Storage..."
for FILE in "$BACKUP_DIR"/*.sql; do
  if [[ -f "$FILE" && -s "$FILE" ]]; then
    echo "Uploading $(basename "$FILE") ..."
    az storage blob upload \
      --account-name "$AZURE_ACCOUNT" \
      --container-name "$AZURE_CONTAINER" \
      --file "$FILE" \
      --name "$(basename "$FILE")" \
      --overwrite true \
      --only-show-errors
  else
    echo "Skipping empty or missing file: $FILE"
  fi
done
echo "----------------------------------------"

# --- Step 4: Verify Azure upload ---
echo "Uploaded files in Azure Blob Storage:"
az storage blob list \
  --account-name "$AZURE_ACCOUNT" \
  --container-name "$AZURE_CONTAINER" \
  --output table
echo "----------------------------------------"

# --- Finish ---
echo "Backup completed successfully at $(date)"
echo "Logs saved to: $LOG_FILE"
