#!/bin/bash
# Generate a UGC ad video via the Arcads API (Seedance 2.0)
# Usage: ./scripts/generate-ugc-ad.sh
# Requires: .env with ARCADS_API_KEY or ARCADS_BASIC_AUTH
set -euo pipefail

# Load .env
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Copy .env.example to .env and add your Arcads API key."
  echo "  cp .env.example .env  # then edit and add ARCADS_API_KEY or ARCADS_BASIC_AUTH"
  exit 1
fi
source .env

BASE_URL="${ARCADS_BASE_URL:-https://external-api.arcads.ai}"

# Pick auth method
if [ -n "${ARCADS_BASIC_AUTH:-}" ]; then
  AUTH_HEADER="$ARCADS_BASIC_AUTH"
  AUTH_FLAG=()
elif [ -n "${ARCADS_API_KEY:-}" ]; then
  AUTH_HEADER=""
  AUTH_FLAG=(-u "$ARCADS_API_KEY:")
else
  echo "ERROR: No Arcads auth found in .env. Set ARCADS_API_KEY or ARCADS_BASIC_AUTH."
  exit 1
fi

# Helper: authenticated curl
acurl() {
  if [ -n "$AUTH_HEADER" ]; then
    curl -sS -H "Authorization: $AUTH_HEADER" "$@"
  else
    curl -sS "${AUTH_FLAG[@]}" "$@"
  fi
}

echo "=== 1. Verify API connectivity ==="
HEALTH=$(acurl "$BASE_URL/health" 2>/dev/null || echo "fail")
echo "Health: $HEALTH"

echo ""
echo "=== 2. List products ==="
PRODUCTS=$(acurl "$BASE_URL/v1/products")
echo "$PRODUCTS" | jq -r '.items[]? | "\(.id)  \(.name)"' 2>/dev/null || echo "$PRODUCTS" | head -200

PRODUCT_ID=$(echo "$PRODUCTS" | jq -r '.items[0].id // empty' 2>/dev/null)
if [ -z "$PRODUCT_ID" ]; then
  echo "ERROR: No products found. Create a product in the Arcads dashboard first."
  exit 1
fi
echo "Using product: $PRODUCT_ID"

echo ""
echo "=== 3. Create dated folder + project ==="
TODAY=$(date +%Y-%m-%d)
FOLDER_NAME="Arcads API - $TODAY"

# Check for existing folder
FOLDER_ID=$(acurl "$BASE_URL/v1/products/$PRODUCT_ID/folders" | jq -r ".items[]? | select(.name==\"$FOLDER_NAME\") | .id" 2>/dev/null || echo "")
if [ -z "$FOLDER_ID" ]; then
  FOLDER_ID=$(acurl -X POST -H "Content-Type: application/json" \
    -d "{\"productId\":\"$PRODUCT_ID\",\"name\":\"$FOLDER_NAME\"}" \
    "$BASE_URL/v1/folders" | jq -r .id 2>/dev/null)
  echo "Created folder: $FOLDER_ID"
else
  echo "Reusing folder: $FOLDER_ID"
fi

PROJECT_ID=$(acurl -X POST -H "Content-Type: application/json" \
  -d "{\"productId\":\"$PRODUCT_ID\",\"folderId\":\"$FOLDER_ID\",\"name\":\"$FOLDER_NAME\"}" \
  "$BASE_URL/v1/projects" | jq -r .id 2>/dev/null)
echo "Created project: $PROJECT_ID"

echo ""
echo "=== 4. Upload reference image (RedNote cover) ==="
REF_IMAGE_PATH=""
REF_FILE=""
for f in references/ugc-ad/little-butterfly-cover.webp /tmp/rednote_cover.webp; do
  if [ -f "$f" ]; then
    REF_FILE="$f"
    break
  fi
done
if [ -n "$REF_FILE" ]; then
  # Determine content type from extension
  case "$REF_FILE" in
    *.webp) FT="image/webp" ;;
    *.png)  FT="image/png" ;;
    *.jpg|*.jpeg) FT="image/jpeg" ;;
    *) FT="image/webp" ;;
  esac
  PRESIGN=$(acurl -X POST -H "Content-Type: application/json" \
    -d "{\"fileType\":\"$FT\"}" \
    "$BASE_URL/v1/file-upload/get-presigned-url")
  PRESIGN_URL=$(echo "$PRESIGN" | jq -r .presignedUrl)
  REF_IMAGE_PATH=$(echo "$PRESIGN" | jq -r .filePath)
  curl -sS -o /dev/null -X PUT -H "Content-Type: $FT" \
    --data-binary @"$REF_FILE" "$PRESIGN_URL"
  echo "Uploaded reference image ($REF_FILE): $REF_IMAGE_PATH"
else
  echo "No reference image found — generating text-only"
fi

echo ""
echo "=== 5. Generate UGC video (Seedance 2.0) ==="
PROMPT=$(cat ugc-ad-prompt.md | sed -n '/^```$/,/^```$/p' | sed '1d;$d' | tr '\n' ' ' | sed 's/  */ /g')

if [ -n "$REF_IMAGE_PATH" ]; then
  REF_JSON=",\"referenceImages\":[\"$REF_IMAGE_PATH\"]"
else
  REF_JSON=""
fi

RESPONSE=$(acurl -X POST -H "Content-Type: application/json" \
  -d "{
    \"model\": \"seedance-2.0\",
    \"productId\": \"$PRODUCT_ID\",
    \"prompt\": $(echo "$PROMPT" | jq -Rs .),
    \"aspectRatio\": \"9:16\",
    \"duration\": 10,
    \"resolution\": \"720p\",
    \"audioEnabled\": true,
    \"projectId\": \"$PROJECT_ID\"$REF_JSON
  }" \
  "$BASE_URL/v2/videos/generate")

ASSET_ID=$(echo "$RESPONSE" | jq -r .id 2>/dev/null)
echo "Asset ID: $ASSET_ID"
echo "Response: $RESPONSE" | head -200

if [ -z "$ASSET_ID" ]; then
  echo "ERROR: No asset ID returned. Check the response above."
  exit 1
fi

echo ""
echo "=== 6. Polling for completion ==="
echo "Seedance 2.0 typically takes 2-6 minutes..."
for i in $(seq 1 120); do
  sleep 5
  STATUS=$(acurl "$BASE_URL/v1/assets/$ASSET_ID" | jq -r .status 2>/dev/null || echo "unknown")
  echo "  [$((i*5))s] Status: $STATUS"
  if [ "$STATUS" = "generated" ]; then
    echo ""
    echo "=== SUCCESS! ==="
    acurl "$BASE_URL/v1/assets/$ASSET_ID" | jq '{status, url, data: .data.creditsCharged}'
    echo ""
    echo "Video URL:"
    acurl "$BASE_URL/v1/assets/$ASSET_ID" | jq -r .url
    exit 0
  elif [ "$STATUS" = "failed" ]; then
    echo "=== FAILED ==="
    acurl "$BASE_URL/v1/assets/$ASSET_ID" | jq .
    exit 1
  fi
done

echo "ERROR: Timed out after 10 minutes."
exit 1
