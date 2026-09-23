#!/bin/bash
# Generates an icon candidate with Gemini's image model. Needs a key from
# https://aistudio.google.com/apikey (free tier is enough).
#   GEMINI_API_KEY=... scripts/icon/gen-gemini.sh out.png ["extra style words"]
set -euo pipefail
OUT=${1:?usage: gen-gemini.sh <out.png> [style]}
STYLE=${2:-}
: "${GEMINI_API_KEY:?set GEMINI_API_KEY}"
MODEL=${GEMINI_MODEL:-gemini-2.5-flash-image}
PROMPT="A macOS app icon for a menu bar utility called Downtray. A single rounded-square tile \
in the modern macOS style (like Apple's Mail or Finder icons), filling most of a square canvas, on a \
plain white background. Inside: a clean white inbox tray with a document dropping into it, a small \
downward arrow, and one small red notification dot at the top right. Blue gradient background, soft \
depth, minimal, no text, no letters, centered, high resolution. $STYLE"
BODY=$(jq -n --arg p "$PROMPT" '{contents:[{parts:[{text:$p}]}],generationConfig:{responseModalities:["IMAGE"]}}')
RESP=$(curl -sS "https://generativelanguage.googleapis.com/v1beta/models/$MODEL:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" -H "Content-Type: application/json" -d "$BODY")
DATA=$(printf '%s' "$RESP" | jq -r '.candidates[0].content.parts[] | select(.inlineData) | .inlineData.data' | head -n 1)
if [[ -z "$DATA" ]]; then
    echo "no image in the response:" >&2
    printf '%s\n' "$RESP" | head -c 600 >&2
    exit 1
fi
printf '%s' "$DATA" | base64 -d > "$OUT.raw.png"
# Square it to 1024 and drop the white background outside the tile with the trim script.
python3 "$(dirname "$0")/trim-tile.py" "$OUT.raw.png" "$OUT"
rm -f "$OUT.raw.png"
echo "wrote $OUT"
