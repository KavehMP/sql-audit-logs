#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname "$0")"

# ============================================================
# Usage: ./download-audit-logs.sh <date>
# Example: ./download-audit-logs.sh 2026-03-20
# ============================================================
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <date>"
  echo "Example: $0 2026-03-20"
  exit 1
fi

DATE="$1"

# Validate date format YYYY-MM-DD
if ! [[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: date must be in YYYY-MM-DD format (e.g. 2026-03-20)"
  exit 1
fi

# ============================================================
# Load env vars
# ============================================================
ENV_FILE="$SCRIPT_DIR/.env"
SAS_TOKEN=$(grep '^BLOB-SAS-TOKEN=' "$ENV_FILE" | cut -d'=' -f2-)
BASE_FOLDER_URL=$(grep '^BLOB-CONTAINER-FOLDER-POINTER=' "$ENV_FILE" | cut -d'=' -f2-)

STORAGE_ACCOUNT="trkspsfcrprodqhddata"
CONTAINER="sqldbauditlogs"
BLOB_BASE_PATH=$(echo "$BASE_FOLDER_URL" | sed "s|https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/||")
BLOB_PREFIX="${BLOB_BASE_PATH}${DATE}/"
OUTPUT_DIR="$SCRIPT_DIR/${DATE}-audit-log"
SQL_SA_PASSWORD="YourStrong@Passw0rd123"

echo "========================================"
echo " SQL Audit Log Downloader"
echo " Date: $DATE"
echo "========================================"
echo ""

# ============================================================
# Step 1: Ensure Docker is running
# ============================================================
echo "[1/5] Checking Docker..."
if ! docker info > /dev/null 2>&1; then
  echo "  Docker is not running. Starting Docker Desktop..."
  open -a Docker
  until docker info > /dev/null 2>&1; do sleep 2; done
  echo "  Docker is ready."
else
  echo "  Docker is already running."
fi

# ============================================================
# Step 2: Ensure SQL Server container is running
# ============================================================
echo ""
echo "[2/5] Checking SQL Server container..."
CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' mssql-audit-reader 2>/dev/null || echo "missing")

if [[ "$CONTAINER_STATUS" != "running" ]]; then
  echo "  Starting SQL Server container..."
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d
else
  echo "  Container is already running."
fi

# Wait for SQL Server to accept connections
echo "  Waiting for SQL Server to be ready..."
MAX_RETRIES=20
RETRIES=0
until docker exec mssql-audit-reader /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$SQL_SA_PASSWORD" -No \
  -Q "SELECT 1" > /dev/null 2>&1; do
  RETRIES=$((RETRIES + 1))
  if [[ $RETRIES -ge $MAX_RETRIES ]]; then
    echo "  Error: SQL Server did not become ready in time."
    exit 1
  fi
  sleep 3
done
echo "  SQL Server is ready."

# ============================================================
# Step 3: Download XEL files from Azure Blob Storage
# ============================================================
echo ""
echo "[3/5] Downloading audit logs for $DATE..."
mkdir -p "$OUTPUT_DIR"

LIST_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}?restype=container&comp=list&prefix=${BLOB_PREFIX}&${SAS_TOKEN}"
BLOB_LIST=$(curl -s "$LIST_URL")
BLOB_NAMES=$(echo "$BLOB_LIST" | tr '<' '\n' | sed -n 's/^Name>\(.*\)/\1/p')

if [[ -z "$BLOB_NAMES" ]]; then
  echo "  No blobs found under $BLOB_PREFIX"
  exit 1
fi

TOTAL=$(echo "$BLOB_NAMES" | wc -l | tr -d ' ')
echo "  Found $TOTAL files."

COUNT=0
while IFS= read -r BLOB_NAME; do
  FILE_NAME=$(basename "$BLOB_NAME")
  DEST="$OUTPUT_DIR/$FILE_NAME"
  if [[ -f "$DEST" ]]; then
    echo "  [skip] $FILE_NAME already exists"
  else
    DOWNLOAD_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}?${SAS_TOKEN}"
    COUNT=$((COUNT + 1))
    echo "  [$COUNT/$TOTAL] Downloading $FILE_NAME..."
    curl -s -L -o "$DEST" "$DOWNLOAD_URL"
  fi
done <<< "$BLOB_NAMES"
echo "  Download complete. Files in: $OUTPUT_DIR"

# ============================================================
# Step 4: Ensure AuditDB and AuditLogs table exist
# ============================================================
echo ""
echo "[4/5] Checking AuditDB and AuditLogs table..."

docker exec mssql-audit-reader /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$SQL_SA_PASSWORD" -No \
  -Q "IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = 'AuditDB')
      BEGIN
          CREATE DATABASE AuditDB;
          PRINT 'AuditDB created.';
      END
      ELSE
          PRINT 'AuditDB already exists.';"

# ============================================================
# Step 5: Import XEL files into AuditLogs table
# ============================================================
echo ""
echo "[5/5] Importing audit logs into AuditDB.dbo.AuditLogs..."

XEL_PATH="/var/opt/audit-logs/${DATE}-audit-log/*.xel"

docker exec mssql-audit-reader /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$SQL_SA_PASSWORD" -No \
  -d AuditDB \
  -Q "
-- Check if data for this date already exists
IF EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'AuditLogs'
) AND EXISTS (
    SELECT 1 FROM AuditLogs WHERE CAST(event_time AS DATE) = '$DATE'
)
BEGIN
    PRINT 'Data for $DATE already exists in AuditLogs. Skipping import.';
END
ELSE
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'AuditLogs')
    BEGIN
        PRINT 'Creating AuditLogs table and importing data...';
        SELECT * INTO AuditLogs
        FROM sys.fn_get_audit_file('$XEL_PATH', DEFAULT, DEFAULT);

        CREATE INDEX IX_AuditLogs_EventTime  ON AuditLogs (event_time);
        CREATE INDEX IX_AuditLogs_Principal  ON AuditLogs (server_principal_name);
        PRINT 'Table created and data imported.';
    END
    ELSE
    BEGIN
        PRINT 'Appending data for $DATE into existing AuditLogs table...';
        INSERT INTO AuditLogs
        SELECT * FROM sys.fn_get_audit_file('$XEL_PATH', DEFAULT, DEFAULT);
        PRINT 'Data appended.';
    END

    DECLARE @rows INT = (SELECT COUNT(*) FROM AuditLogs WHERE CAST(event_time AS DATE) = '$DATE');
    PRINT 'Rows imported for $DATE: ' + CAST(@rows AS VARCHAR);
END
" -t 300

echo ""
echo "========================================"
echo " All done!"
echo " Query your data:"
echo "   SELECT * FROM AuditDB.dbo.AuditLogs"
echo "   WHERE CAST(event_time AS DATE) = '$DATE'"
echo "   ORDER BY event_time;"
echo "========================================"
