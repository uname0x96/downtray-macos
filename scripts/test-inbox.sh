#!/bin/bash
# Tier 2 of the test pyramid: bridge-driven scenarios.
#
# The same scenario language (`inbox-cli` event grammar) drives two targets:
#   headless   the presenter in-process against an in-memory file system (no app, no window)
#   attached   the running debug build, through its localhost bridge, with real files in ~/Downloads
#
#   scripts/test-inbox.sh              # headless only
#   scripts/test-inbox.sh attached     # attached only (needs the debug app running)
#   scripts/test-inbox.sh both
#
# The attached run writes and removes its own files (inbox-test-<pid>.*) in ~/Downloads and opens
# one of them with the default text editor, as a user pressing Return would.
#
# Every step sends one line and asserts on the JSON snapshot that comes back, so a step fails
# on what the app believes, not on what the screen looks like. No fixed sleeps: waits poll for a
# named condition with a deadline.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI="$ROOT/.build/debug/inbox-cli"
MODE=${1:-headless}
STEPS=0
LAST=""
ERRORS=$(mktemp -t inbox-errors)
trap 'cleanup' EXIT

cleanup() {
    if [[ -n "${SESSION_PID:-}" ]]; then
        exec 3>&- 4<&-
        wait "$SESSION_PID" 2>/dev/null || true
        unset SESSION_PID
    fi
    rm -rf "$ERRORS" "${FIFO_DIR:-}"
}

fail() {
    echo "FAIL (step $STEPS): $*" >&2
    echo "last snapshot: $LAST" >&2
    exit 1
}

# Starts `inbox-cli repl` in the background behind two named pipes (bash 3.2 has no coproc).
# Its stdout is read line by line (one snapshot per request); stderr goes to a file so a
# rejected event can be asserted separately.
start_session() {
    FIFO_DIR=$(mktemp -d -t inbox-session)
    mkfifo "$FIFO_DIR/in" "$FIFO_DIR/out"
    "$CLI" repl --compact "$@" <"$FIFO_DIR/in" >"$FIFO_DIR/out" 2>>"$ERRORS" &
    SESSION_PID=$!
    exec 3>"$FIFO_DIR/in" 4<"$FIFO_DIR/out"
    read -r -t 10 LAST <&4 || fail "no initial state from inbox-cli"
}

send() {
    STEPS=$((STEPS + 1))
    echo "$1" >&3
    read -r -t 15 LAST <&4 || fail "no reply to '$1'"
}

# expect '<jq boolean expression>' [message]
expect() {
    local result
    result=$(printf '%s' "$LAST" | jq -e "$1" >/dev/null 2>&1 && echo yes || echo no)
    [[ "$result" == yes ]] || fail "${2:-expected $1}"
}

# expect_error <substring>: the previous send must have been rejected with this text.
expect_error() {
    tail -n 1 "$ERRORS" | grep -q -- "$1" || fail "expected error containing '$1', got: $(tail -n 1 "$ERRORS")"
}

# wait_for '<jq boolean expression>' <seconds> [message] [shell]: polls `state` until true.
# With a 4th argument the condition is a shell test instead (for on-disk effects).
wait_for() {
    local deadline=$((SECONDS + $2))
    while true; do
        send "state"
        if [[ -n "${4:-}" ]]; then
            if eval "$1"; then return; fi
        elif printf '%s' "$LAST" | jq -e "$1" >/dev/null 2>&1; then
            return
        fi
        (( SECONDS < deadline )) || fail "${3:-timed out waiting for $1}"
        sleep 0.1
    done
}

row() { echo ".rows[] | select(.name == \"$1\")"; }

# ---------------------------------------------------------------------------------------------
# The scenario: the spec's success loop and its edge cases, in the language of the model.
# `arrive`/`vanish` are only meaningful headless; attached runs create real files instead.
# ---------------------------------------------------------------------------------------------
headless_scenario() {
    echo "== headless: presenter + fake services"
    start_session
    expect '.panelOpen == false and .rows == [] and .badge == 0' "fresh state"

    send "arrive report.pdf 120k example.com"
    expect ".badge == 1 and ($(row report.pdf) | .unread and .source == \"example.com\" and .kind == \"pdf\")"
    send "arrive photo.png 2m airdrop"
    send "arrive archive.zip 500k"
    expect '.badge == 3 and (.rows | length) == 3'

    send "hotkey"
    expect '.panelOpen and .badge == 3 and .unread == 3' "opening the panel alone marks nothing read; the badge is the unread count"
    expect '.rows[0].name == "archive.zip" and .focused == null and .selection == []' "nothing is selected on open"
    send "down"
    expect '.rows[0].focused and .rows[0].selected' "the first arrow key focuses the top row"

    expect '.filter == "all" and .filters == ["all", "1h", "today", "unread"] and .type == "any"' "the folder was empty at launch, so the Today chip fell back to All"
    send "filter today"; expect '(.rows | length) == 3 and .settings.selectedChip == "today"'
    expect '.counts == {"1h": 3, "today": 3, "unread": 3} and .sections == ["justNow", "justNow", "justNow"]' "chip counts and the recency sections"
    send "filter 1h";     expect '(.rows | length) == 3 and .sections == null' "1h is a flat list"
    send "type docs";     expect '(.rows | length) == 1 and .rows[0].name == "report.pdf" and .rows[0].type == "docs"'
    send "type images";   expect '(.rows | length) == 1 and .rows[0].name == "photo.png"'
    send "type archives"; expect '(.rows | length) == 1 and .rows[0].name == "archive.zip"'
    send "type media";    expect '.rows == [] and .emptyState == "noMatches"' "an empty Type is No matches"
    send "type any";      expect '(.rows | length) == 3 and .settings.typeOverrides == {}'
    send "type map png docs"; expect '.settings.typeOverrides == {"png": "docs"} and (.rows | map(select(.type == "docs")) | length) == 2' "an override wins over the table"
    send "type reset";    expect '.settings.typeOverrides == {}'
    send "search zip";    expect '(.rows | length) == 1 and .rows[0].name == "archive.zip"' "the extension matches"
    send "search example"; expect '(.rows | length) == 1 and .rows[0].name == "report.pdf"' "the source host matches"
    send "search";        expect '(.rows | length) == 3'
    send "filter unread"; expect '(.rows | length) == 3'
    send "read report.pdf"; expect '(.rows | length) == 2 and .badge == 2' "a read row leaves the Unread chip and the badge follows"
    send "unread report.pdf"; expect '(.rows | length) == 3 and .badge == 3'
    send "filter all";    expect '(.rows | length) == 3 and .settings.selectedChip == "all"' "the chip is remembered"

    send "open report.pdf"
    expect "$(row report.pdf) | .unread == false" "open marks the row read"
    send "copy report.pdf"
    expect '.toast.message == "Path copied"'
    send "copy-name report.pdf"
    expect '.toast.message == "Name copied"'

    send "unzip archive.zip"
    expect '.toast.message | startswith("Extracted archive.zip")'
    send "unzip photo.png"
    expect_error "not a .zip"

    send "trash photo.png"
    expect '(.rows | map(.name) | index("photo.png")) == null and .undo.count == 1 and .undo.ready' "trash removes the row and offers undo"
    send "undo"
    expect "($(row photo.png) | .unread == false) and .undo == null" "undo puts the file back, read"

    send "vanish report.pdf"
    expect '(.rows | map(.name) | index("report.pdf")) == null' "a vanished file leaves the list"

    send "dest /Users/sample/Documents"
    send "move archive.zip"
    expect '(.rows | map(.name) | index("archive.zip")) == null and (.toast.message | startswith("Moved archive.zip to Documents"))'

    # The primary folder can move (free tier). The picker is scripted with `pick`.
    send "pick /Users/sample/Inbox"
    send "folder change"
    expect '(.folders | length) == 1 and .folders[0].path == "/Users/sample/Inbox" and .folders[0].title == "Inbox" and .rows == []' "moving the primary folder drops the old folder's rows"
    send "arrive notes.pdf 3k"
    expect "$(row notes.pdf) | .folder == \"Inbox\"" "arrivals now come from the new folder"
    send "pick /Users/sample/Downloads"
    send "folder change"
    expect '.folders[0].path == "/Users/sample/Downloads" and (.rows | map(.name) | index("notes.pdf")) == null and (.rows | length) > 0' "moving back rescans Downloads"

    send "hotkey-set cmd+shift+space"
    expect '.settings.hotkey == "⇧⌘Space"'
    send "notify on";  expect '.settings.notifications'
    send "language ja"; expect '.settings.language == "ja"' "a UI language is a setting"
    send "language system"; expect '.settings.language == null'

    send "seen"
    expect '.unread == 0 and .badge == 0'
    send "badge off";  expect '.settings.showBadge == false'
    send "badge on"
    send "keep day";   expect '.settings.retention == "day"'
    send "keep forever"; expect '.settings.retention == "forever"' "Forever is a retention choice"
    send "keep week"
    send "clear-list"; expect '.rows == [] and .emptyState == "nothingNew" and .settings.selectedChip == "all" and .settings.listCleared' "Clear list empties the inbox without touching the files"
    send "arrive after.txt 1k"
    expect '(.rows | map(.name)) == ["after.txt"]' "what arrives after the clear shows"
    send "restore-list"; expect '(.rows | length) > 1 and .rows[0].name == "after.txt" and (.settings.listCleared | not)' "Restore list brings the hidden rows back"
    send "clear-list";  expect '(.rows | length) == 0'
    send "arrive after.txt 1k"
    send "panel close"
    expect '.panelOpen == false and .selection == [] and .focused == null'

    send "undo"
    expect_error "nothing to undo"

    # --- Pro: gated until the (fake) store confirms the purchase --------------------------
    send "history on";  expect_error "needs Pro"
    send "older";       expect '.paywall and .historyMode == false' "Show older files is the Pro sheet without Pro"
    send "paywall off"; expect '.paywall == false'
    send "folder add";  expect_error "needs Pro"
    send "unlock"
    expect '.settings.pro and .toast.message == "Pro unlocked. Thank you!"' "the fake purchase unlocks Pro"

    send "pick /Users/sample/Scans"
    send "folder add"
    expect '.settings.extraFolders == ["/Users/sample/Scans"] and (.folders[] | select(.title == "Scans") | .custom and .enabled)'
    send "folder add"
    expect '.settings.extraFolders == ["/Users/sample/Scans"] and (.toast.message | endswith("already watched"))' "picking the same folder twice is a toast, not a second entry"
    send "arrive /Users/sample/Scans/scan.pdf 9k"
    expect "$(row scan.pdf) | .folder == \"Scans\"" "a file in the extra folder shows up"

    send "search scan"
    expect '.query == "scan" and (.rows | length) == 1 and .rows[0].name == "scan.pdf"' "the Pro inbox searches by name"
    send "search zzz";  expect '.emptyState == "noMatches"' "no hits in the inbox is No matches, not Nothing new"
    send "history on"
    expect '.historyMode and .query == "" and (.rows | map(.name) | index("archive.zip")) != null' "history still lists the moved archive and starts with an empty search"
    send "search scan"
    expect '.query == "scan" and (.rows | length) == 1 and .rows[0].name == "scan.pdf"'
    send "search zzz";  expect '.emptyState == "noMatches"' "a search with no hits is History's own empty state"
    send "search"
    send "history gone"
    expect '.historyFilter == "gone" and (.rows | length) > 0 and all(.rows[]; .missing)' "the Gone segment shows only files that left"
    send "forget archive.zip"
    expect '(.rows | map(.name) | index("archive.zip")) == null' "a Gone row can be removed from History"
    send "history all"
    send "history off"
    expect '.historyMode == false and .query == ""'

    send "rule add Receipts host=example.com ext=pdf then move /Users/sample/Receipts"
    expect '.settings.rules | length == 1 and .[0].name == "Receipts"'
    send "rule add receipts then trash"
    expect_error "already exists"
    send "arrive receipt.pdf 30k example.com"
    expect '(.rows | map(.name) | index("receipt.pdf")) == null and (.toast.message | startswith("Moved receipt.pdf to Receipts"))' "an arrival rule moves the file"
    send "rule disable Receipts"
    send "arrive receipt2.pdf 30k example.com"
    expect "$(row receipt2.pdf) | .unread" "a disabled rule does nothing"

    send "rule add Junk ext=dmg then suggest-trash"
    send "arrive tool.dmg 80m"
    expect '.suggestion.message == "Junk: move tool.dmg to the Trash?"' "suggest-trash asks first"
    send "accept"
    expect '.suggestion == null and (.rows | map(.name) | index("tool.dmg")) == null and .undo.count == 1' "accepting the suggestion trashes with undo"
    send "rule remove Junk"
    send "rule remove Receipts"
    expect '.settings.rules == []'

    send "arrive scan.pdf 4k"
    expect '[.rows[] | select(.name == "scan.pdf")] | length == 2 and all(.showFolder)' "duplicate names show their folder"
    send "folder remove Scans"
    expect '.settings.extraFolders == [] and ([.rows[] | select(.name == "scan.pdf")] | length == 1 and .[0].folder == "Downloads")' "removing the folder drops its rows"
    send "history clear"
    expect '.historyCount == 0'
    send "pro off"
    expect '.settings.pro == false'
    echo "   $STEPS steps passed"
    cleanup
}

attached_scenario() {
    echo "== attached: the running app through the debug bridge"
    # Globals on purpose: the EXIT trap runs after this function's locals are gone.
    downloads="$HOME/Downloads"
    stamp="inbox-test-$$"
    note="$downloads/$stamp.txt"
    zip="$downloads/$stamp.zip"
    extracted="$downloads/$stamp"
    watch="$downloads/$stamp-watch"
    dest="$downloads/$stamp-dest"
    trap 'rm -rf "$note" "$zip" "$extracted" "$extracted"-*; cleanup' EXIT

    start_session --remote
    send "reset"
    send "panel close"
    expect '.panelOpen == false'

    echo "hello from the test script" > "$note"
    wait_for "$(row "$stamp.txt") | .unread" 8 "the watcher did not report the new file"

    send "hotkey"
    expect '.panelOpen' "hotkey shows the popover"
    expect '.focused == null' "nothing is selected on open"
    send "down"
    expect ".focused == \"$note\"" "the first arrow key focuses the new file"

    send "copy"
    expect '.toast.message == "Path copied"'
    [[ "$(pbpaste)" == "$note" ]] || fail "pasteboard does not hold the path"

    send "open"
    expect "$(row "$stamp.txt") | .unread == false"
    # Opening may activate the editor and close the transient popover; the model follows either way.

    # A real zip goes through /usr/bin/ditto inside the sandbox.
    mkdir -p "$extracted-src" && echo "zipped" > "$extracted-src/inner.txt"
    (cd "$downloads" && /usr/bin/ditto -c -k --keepParent "$stamp-src" "$stamp.zip")
    rm -rf "$extracted-src"
    wait_for "$(row "$stamp.zip") | .kind == \"archive\"" 8 "the zip did not show up"
    send "unzip $stamp.zip"
    send "settle"
    expect '.toast.message | startswith("Extracted")' "unzip reports its output"
    [[ -f "$extracted/$stamp-src/inner.txt" || -f "$extracted-1/$stamp-src/inner.txt" ]] || fail "ditto did not extract next to the archive"

    send "trash $stamp.txt"
    send "settle"
    expect '.undo.count == 1' "trash offers undo"
    [[ ! -e "$note" ]] || fail "file still in Downloads after trash"
    send "undo"
    send "settle"
    [[ -e "$note" ]] || fail "undo did not restore the file"
    expect "$(row "$stamp.txt") | .unread == false"

    send "trash $stamp.txt"
    wait_for '.undo == null' 8 "undo did not expire after 5 s"

    send "panel close"
    expect '.panelOpen == false'
    send "hotkey"
    expect '.panelOpen' "hotkey shows the popover again"
    send "hotkey"
    expect '.panelOpen == false' "hotkey hides the popover"

    # --- Pro against the real app. `pro on` stands in for the store; `pick` answers the
    # folder panel. The extra folder lives under ~/Downloads because the sandbox can only read
    # what a bookmark or entitlement covers, and a scripted pick grants no bookmark.
    send "pro on"
    expect '.settings.pro'
    mkdir -p "$watch" "$dest"
    send "pick $watch"
    send "folder add"
    expect ".settings.extraFolders == [\"$watch\"]"
    echo "scanned" > "$watch/$stamp-scan.txt"
    wait_for "$(row "$stamp-scan.txt") | .folder == \"$stamp-watch\"" 8 "the extra folder is not being watched"

    send "history on"
    expect ".historyMode and ($(row "$stamp-scan.txt") | .id != null)"
    send "search $stamp-scan"
    expect '(.rows | length) == 1'
    send "search"
    send "history off"

    send "rule add $stamp-rule ext=pdf then move $dest"
    echo "%PDF" > "$watch/$stamp-report.pdf"
    wait_for "[ -f \"$dest/$stamp-report.pdf\" ]" 8 "the rule did not move the pdf" shell
    send "settle"
    expect "(.rows | map(.name) | index(\"$stamp-report.pdf\")) == null"

    send "rule add $stamp-ask ext=txt then suggest-trash"
    echo "junk" > "$watch/$stamp-junk.txt"
    wait_for ".suggestion.message == \"$stamp-ask: move $stamp-junk.txt to the Trash?\"" 8 "no suggestion for the txt"
    send "accept"
    send "settle"
    [[ ! -e "$watch/$stamp-junk.txt" ]] || fail "accepting the suggestion did not trash the file"

    send "rule remove $stamp-rule"
    send "rule remove $stamp-ask"
    send "folder remove $stamp-watch"
    # Only this run's rules and folder; the user's own settings stay.
    expect "([.settings.rules[].name] | map(select(startswith(\"$stamp\"))) == []) and (.settings.extraFolders | index(\"$watch\")) == null"
    send "pro off"
    expect '.settings.pro == false'
    echo "   $STEPS steps passed"
}

[[ -x "$CLI" ]] || { echo "build first: swift build" >&2; exit 1; }
case "$MODE" in
    headless) headless_scenario ;;
    attached) attached_scenario ;;
    both) headless_scenario; STEPS=0; attached_scenario ;;
    *) echo "usage: $0 [headless|attached|both]" >&2; exit 2 ;;
esac
echo "OK"
