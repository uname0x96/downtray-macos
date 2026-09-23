#!/bin/bash
# Builds the AppIcon.appiconset from one 1024×1024 PNG (any source: drawn, generated, designed).
#   scripts/icon/make-iconset.sh icon-1024.png
set -euo pipefail
SRC=${1:?usage: make-iconset.sh <1024.png>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEST="$ROOT/macOS/Arrivals/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$DEST"
rm -f "$DEST"/*.png
entries=()
for pt in 16 32 128 256 512; do
    for scale in 1 2; do
        px=$((pt * scale))
        name="icon_${pt}x${pt}@${scale}x.png"
        sips -s format png -z "$px" "$px" "$SRC" --out "$DEST/$name" >/dev/null
        entries+=("{\"filename\":\"$name\",\"idiom\":\"mac\",\"scale\":\"${scale}x\",\"size\":\"${pt}x${pt}\"}")
    done
done
printf '{"images":[%s],"info":{"author":"xcode","version":1}}\n' "$(IFS=,; echo "${entries[*]}")" | jq . > "$DEST/Contents.json"
echo "wrote $DEST"
