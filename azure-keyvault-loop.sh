#!/bin/bash

KEY_VAULT_NAME="testkeyvault"
SEARCH_STRING="xxxx-xxxx-xxxx-xxxx-xxxx"



echo "🔍 Searching for: $SEARCH_STRING"
echo "Key Vault: $KEY_VAULT_NAME"
echo "Filter: secrets starting with 'my-connections'"
echo "-----------------------------------"

FOUND=false

# Only fetch secrets whose name starts with "airflow-connections"
SECRET_NAMES=$(az keyvault secret list \
  --vault-name "$KEY_VAULT_NAME" \
  --query "[?starts_with(name, 'my-connections')].name" \
  --output tsv)

if [ -z "$SECRET_NAMES" ]; then
  echo "⚠️  No secrets found starting with 'my-connections'"
  exit 0
fi

for SECRET_NAME in $SECRET_NAMES; do
  SECRET_VALUE=$(az keyvault secret show \
    --vault-name "$KEY_VAULT_NAME" \
    --name "$SECRET_NAME" \
    --query "value" \
    --output tsv 2>/dev/null)

  if echo "$SECRET_VALUE" | grep -Fq "$SEARCH_STRING"; then
    echo "✅ FOUND in secret: $SECRET_NAME"
    echo "$SECRET_VALUE" | grep -F --color=always "$SEARCH_STRING"
    echo ""
    FOUND=true
  else
    echo "❌ Not found in: $SECRET_NAME"
  fi
done

echo "-----------------------------------"
if [ "$FOUND" = false ]; then
  echo "❌ String not found in any 'my-connections' secret."
else
  echo "✅ Search complete — match(es) found above."
fi

