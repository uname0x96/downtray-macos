#!/bin/bash
# Localization lint: every `String(localized: "key", defaultValue: …)` in the app has a catalog
# entry, every catalog entry is used, and each shipped language translates every key.
#
#   scripts/check-strings.sh            # exit 1 on any finding
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import glob, json, re, sys
root = sys.argv[1]
catalog = json.load(open(f"{root}/macOS/Downtray/Localizable.xcstrings"))
languages = ["en", "ja", "de", "fr"]
pattern = re.compile(r'String\(localized:\s*"([^"]+)"')
used = set()
for path in glob.glob(f"{root}/macOS/Downtray/*.swift"):
    used |= set(pattern.findall(open(path).read()))
strings = catalog["strings"]
problems = []
for key in sorted(used - set(strings)):
    problems.append(f"missing from catalog: {key}")
for key in sorted(set(strings) - used):
    problems.append(f"unused in code: {key}")
for key, entry in sorted(strings.items()):
    for lang in languages:
        if lang not in entry.get("localizations", {}):
            problems.append(f"no {lang} translation: {key}")
# A user-facing literal that bypassed the catalog: Text("…") / Button("…") with letters.
literal = re.compile(r'\b(Text|Button|Toggle|Section|LabeledContent|Picker|TextField|Label)\("[A-Za-z][^"]*"')
for path in glob.glob(f"{root}/macOS/Downtray/*.swift"):
    for number, line in enumerate(open(path), 1):
        if literal.search(line) and "verbatim" not in line:
            problems.append(f"literal UI string: {path.split('/')[-1]}:{number}")
for problem in problems:
    print(problem)
print(f"{len(strings)} keys, {len(languages)} languages, {len(problems)} problems")
sys.exit(1 if problems else 0)
PY
