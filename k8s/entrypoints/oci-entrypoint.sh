#!/bin/bash
# OCI sizing script entrypoint for Kubernetes Jobs.
# Env vars:
#   OCI_CONFIG_BASE64  — base64-encoded ~/.oci/config content
#   OCI_KEY_BASE64     — base64-encoded OCI API private key
#   ACCOUNT_ID, SESSION_ID, CALLBACK_URL, CALLBACK_API_KEY
#   OCI_WORKLOAD       — workload type (default: all)
set -euo pipefail

echo "=== OCI Sizing Job Starting ==="

# Write OCI config
mkdir -p ~/.oci
echo "${OCI_CONFIG_BASE64}" | base64 -d > ~/.oci/config
echo "${OCI_KEY_BASE64}" | base64 -d > ~/.oci/key.pem
chmod 600 ~/.oci/config ~/.oci/key.pem
# Patch key path in config if needed
sed -i "s|key_file=.*|key_file=/root/.oci/key.pem|g" ~/.oci/config

WORKLOAD="${OCI_WORKLOAD:-all}"

echo "Running OCI sizing script (workload=$WORKLOAD)..."
python3 /scripts/CVOracleCloudSizingScript.py \
    --workload="${WORKLOAD}" \
    --output-format=both

JSON_FILE=$(find Metrics -name 'oci_sizing_*.json' 2>/dev/null | sort | tail -n1)
if [ -z "$JSON_FILE" ]; then
    echo "ERROR: No JSON output file found"
    exit 1
fi
echo "JSON output: $JSON_FILE"

if [ -n "${CALLBACK_URL:-}" ]; then
    INLINE_JSON=$(cat "$JSON_FILE")
    curl -X POST "${CALLBACK_URL}/api/v1/sales-ai-hub/accounts/${ACCOUNT_ID}/sizing-reports" \
         -H "Content-Type: application/json" \
         -H "x-api-key: ${CALLBACK_API_KEY:-}" \
         -d "{\"account_id\":\"${ACCOUNT_ID}\",\"session_id\":\"${SESSION_ID:-}\",\"inline_json\":${INLINE_JSON},\"index_to_azure\":true}"
    echo "Callback sent to Sales AI Hub"
fi

echo "=== OCI Sizing Job Complete ==="
