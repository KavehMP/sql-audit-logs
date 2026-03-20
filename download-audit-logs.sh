#!/bin/bash
set -euo pipefail

# Load env vars (keys contain dashes, can't use source directly)
ENV_FILE="$(dirname "$0")/.env"
SAS_TOKEN=$(grep '^BLOB-SAS-TOKEN=' "$ENV_FILE" | cut -d'=' -f2-)
FOLDER_URL=$(grep '^BLOB-CONTAINER-FOLDER-POINTER=' "$ENV_FILE" | cut -d'=' -f2-)
STORAGE_ACCOUNT="trkspsfcrprodqhddata"
CONTAINER="sqldbauditlogs"
BLOB_PREFIX="trk-spsf-drprod-wdz-sqls/dbtrkspsfprod/SqlDbAuditing_Audit_NoRetention/2026-03-20/"
OUTPUT_DIR="$(dirname "$0")/2026-03-20-audit-log"

mkdir -p "$OUTPUT_DIR"

echo "Listing blobs under: $BLOB_PREFIX"

# List all blobs under the folder using the Azure Blob REST API
LIST_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}?restype=container&comp=list&prefix=${BLOB_PREFIX}&${SAS_TOKEN}"

BLOB_LIST=$(curl -s "$LIST_URL")

# Extract blob names from the XML response
BLOB_NAMES=$(echo "$BLOB_LIST" | tr '<' '\n' | sed -n 's/^Name>\(.*\)/\1/p')

if [[ -z "$BLOB_NAMES" ]]; then
  echo "No blobs found under $BLOB_PREFIX"
  exit 1
fi

echo "Found blobs:"
echo "$BLOB_NAMES"
echo ""

# Download each blob
while IFS= read -r BLOB_NAME; do
  FILE_NAME=$(basename "$BLOB_NAME")
  DEST="$OUTPUT_DIR/$FILE_NAME"
  DOWNLOAD_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}?${SAS_TOKEN}"

  echo "Downloading $FILE_NAME ..."
  curl -s -L -o "$DEST" "$DOWNLOAD_URL"
  echo "  -> saved to $DEST"
done <<< "$BLOB_NAMES"

echo ""
echo "Done. Files saved to: $OUTPUT_DIR"
