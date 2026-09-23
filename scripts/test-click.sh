#!/bin/bash
# Tier 3, semi-manual: the popover through real mouse clicks (CGEvent), the way a user does it.
# Reproduces two bugs: "first click in the popover is swallowed" (open the panel from the
# status item while another app is frontmost, click a row once, expect the file to open) and
# "a second click on the status item reopens instead of closing".
#
#   scripts/test-click.sh [rowIndex] [frontmostApp]      # defaults: 1, Finder
#
# Needs the debug app running and Accessibility permission for the terminal (CGEvent posting).
# Opens one file with its default app and closes TextEdit/Preview windows afterwards.
set -euo pipefail
ROW=${1:-1}
FRONT=${2:-Finder}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLICK=/tmp/inbox-click
bridge() { printf '%s\n' "$1" | nc -w 2 127.0.0.1 8791 | head -n 1; }

swiftc -O "$ROOT/scripts/click.swift" -o "$CLICK" 2>/dev/null
name="inbox-click-$$.txt"
echo "click test" > "$HOME/Downloads/$name"
trap 'rm -f "$HOME/Downloads/$name"; osascript -e "tell application \"TextEdit\" to close every window" >/dev/null 2>&1 || true' EXIT
sleep 1.5
# A fresh model: rows for files that are gone (earlier test runs) would be dismissed by the
# click instead of opened, and the assertion below would misread that.
bridge reset >/dev/null
bridge "panel close" >/dev/null
osascript -e "tell application \"$FRONT\" to activate" >/dev/null
sleep 0.6

status=$(bridge frames | jq -c '(.error | fromjson).statusItem')
sx=$(jq '.x + .w / 2' <<<"$status")
sy=$(jq '.y + .h / 2' <<<"$status")

# Status item twice: open, then close (the mouse-down closes the transient popover and the
# mouse-up's action must not reopen it).
"$CLICK" "$sx" "$sy"; sleep 0.8
[[ "$(bridge state | jq '.snapshot.panelOpen')" == true ]] || { echo "FAIL: the status item click did not open the panel" >&2; exit 1; }
"$CLICK" "$sx" "$sy"; sleep 0.8
[[ "$(bridge state | jq '.snapshot.panelOpen')" == false ]] || { echo "FAIL: a second status item click left the panel open" >&2; exit 1; }
echo "OK: status item twice opens then closes"

"$CLICK" "$sx" "$sy"
sleep 0.8
panel=$(bridge frames | jq -c '(.error | fromjson).panel')
[[ "$panel" != null ]] || { echo "FAIL: the status item click did not open the panel" >&2; exit 1; }
target=$(bridge state | jq -r ".snapshot.rows[$ROW].name")
# Popover chrome is ~13 pt; the first row's centre sits ~98 pt below the content top; rows
# are 48 pt apart (see PopoverView). The search field (Pro) would shift this by 36 pt.
"$CLICK" "$(jq '.x + .w / 2' <<<"$panel")" "$(jq ".y + 13 + 98 + $ROW * 48" <<<"$panel")"
sleep 0.8
after=$(bridge state)
open=$(jq '.snapshot.panelOpen' <<<"$after")
unread=$(jq --arg t "$target" '.snapshot.rows[] | select(.name == $t) | .unread' <<<"$after")
# One click = select + open. Opening activates the file's app, which closes the transient
# popover, and the row is no longer unread.
if [[ "$open" == false && "$unread" != true ]]; then
    echo "OK: one click on row $ROW ($target) opened it with $FRONT frontmost"
else
    echo "FAIL: first click on row $ROW ($target) was swallowed (panelOpen=$open unread=$unread)" >&2
    exit 1
fi
