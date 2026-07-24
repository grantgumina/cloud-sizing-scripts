#!/bin/bash
# Azure sizing script entrypoint for Kubernetes Jobs.
# Env vars injected from K8s Secret + ConfigMap:
#   AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET  — Service Principal credentials
#   AZURE_SUBSCRIPTION_IDS                                  — comma-separated (optional)
#   ACCOUNT_ID                                              — Sales AI Hub account_id
#   SESSION_ID                                              — Sales AI Hub session_id (optional)
#   OUTPUT_BLOB_SAS_URL                                     — Azure Blob SAS URL to upload JSON
#   CALLBACK_URL                                            — Sales AI Hub callback endpoint
#   SIZING_TYPES                                            — comma-separated Types param (optional)
#   ENV_TAG_VALUES                                          — comma-separated env tag filter (optional)
set -euo pipefail

echo "=== Azure Sizing Job Starting ==="
echo "Account: ${ACCOUNT_ID}"

# Authenticate
pwsh -Command "
\$cred = [System.Management.Automation.PSCredential]::new(
    '${AZURE_CLIENT_ID}',
    (ConvertTo-SecureString '${AZURE_CLIENT_SECRET}' -AsPlainText -Force)
)
Connect-AzAccount -ServicePrincipal -Tenant '${AZURE_TENANT_ID}' -Credential \$cred -ErrorAction Stop
Write-Host 'Azure authentication successful'
"

# Build script arguments. -NonInteractive forces the shared console layer into plain, pipe-safe output
# (no progress bars / ANSI) so pod logs stay clean and the exit code is reliable under `set -euo pipefail`.
ARGS="-OutputFormat both -NonInteractive"
if [ -n "${SIZING_TYPES:-}" ]; then
    ARGS="$ARGS -Types ${SIZING_TYPES}"
fi
if [ -n "${AZURE_SUBSCRIPTION_IDS:-}" ]; then
    SUBS=$(echo "${AZURE_SUBSCRIPTION_IDS}" | tr ',' ' ')
    ARGS="$ARGS -Subscriptions ${SUBS}"
fi
if [ -n "${ENV_TAG_VALUES:-}" ]; then
    ARGS="$ARGS -EnvTagValues ${ENV_TAG_VALUES}"
fi

echo "Running: CVAzureCloudSizingScript.ps1 $ARGS"

# Run sizing script
pwsh -Command "
cd /scripts
./CVAzureCloudSizingScript.ps1 $ARGS
"

# Find the JSON output
JSON_FILE=$(find . -name 'azure_sizing_*.json' | sort | tail -n1)
if [ -z "$JSON_FILE" ]; then
    echo "ERROR: No JSON output file found"
    exit 1
fi
echo "JSON output: $JSON_FILE"

# Upload to Blob if SAS URL provided
if [ -n "${OUTPUT_BLOB_SAS_URL:-}" ]; then
    BLOB_NAME="azure_sizing_${ACCOUNT_ID}_$(date +%Y%m%d%H%M%S).json"
    UPLOAD_URL="${OUTPUT_BLOB_SAS_URL%\?*}/${BLOB_NAME}?${OUTPUT_BLOB_SAS_URL#*\?}"
    curl -X PUT -H "x-ms-blob-type: BlockBlob" -H "Content-Type: application/json" \
         --data-binary "@${JSON_FILE}" "${UPLOAD_URL}"
    FILE_URL="${OUTPUT_BLOB_SAS_URL%\?*}/${BLOB_NAME}"
    echo "Uploaded to Blob: $FILE_URL"
else
    # No blob: read inline and POST directly
    FILE_URL=""
fi

# POST callback to Sales AI Hub
if [ -n "${CALLBACK_URL:-}" ]; then
    if [ -n "$FILE_URL" ]; then
        BODY="{\"account_id\":\"${ACCOUNT_ID}\",\"session_id\":\"${SESSION_ID:-}\",\"file_url\":\"${FILE_URL}\",\"index_to_azure\":true}"
    else
        JSON_B64=$(base64 -w0 "$JSON_FILE")
        INLINE_JSON=$(cat "$JSON_FILE")
        BODY="{\"account_id\":\"${ACCOUNT_ID}\",\"session_id\":\"${SESSION_ID:-}\",\"inline_json\":${INLINE_JSON},\"index_to_azure\":true}"
    fi

    curl -X POST "${CALLBACK_URL}/api/v1/sales-ai-hub/accounts/${ACCOUNT_ID}/sizing-reports" \
         -H "Content-Type: application/json" \
         -H "x-api-key: ${CALLBACK_API_KEY:-}" \
         -d "$BODY"
    echo "Callback sent to Sales AI Hub"
fi

echo "=== Azure Sizing Job Complete ==="
