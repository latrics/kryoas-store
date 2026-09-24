#!/bin/bash
# Usage: publish.sh /path/to/signed-release.apk ["description text"]
# Copies a freshly signed release APK into the F-Droid repo, regenerates the
# index, updates the dashboard's V2 (client / MAVLink signing) entry to match,
# and pushes it all to GitHub Pages so testers get the update notification.
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 /path/to/signed-release.apk [\"description text\"]"
  exit 1
fi

APK_SRC="$1"
DESCRIPTION="${2:-Updated build.}"
STORE_DIR="$HOME/kryoas-store"
FDROID_DIR="$STORE_DIR/fdroid"
JDK_BIN="$HOME/jdk/bin"
FDROID_BIN="$HOME/venv-fdroid/bin/fdroid"
PYTHON_BIN="$HOME/venv-fdroid/bin/python3"

export PATH="$JDK_BIN:$PATH"
export JAVA_HOME="$HOME/jdk"

if [ ! -f "$APK_SRC" ]; then
  echo "APK not found: $APK_SRC"
  exit 1
fi

cp "$APK_SRC" "$FDROID_DIR/repo/KryoasControlStation64.apk"

cd "$FDROID_DIR"
"$FDROID_BIN" update

VERSION_NAME=$("$PYTHON_BIN" -c "
from androguard.core.apk import APK
a = APK('$FDROID_DIR/repo/KryoasControlStation64.apk')
print(a.get_androidversion_name())
" 2>/dev/null)
TODAY=$(date +%F)

cd "$STORE_DIR"
"$PYTHON_BIN" - "$VERSION_NAME" "$DESCRIPTION" "$TODAY" <<'PYEOF'
import json, sys

version, description, today = sys.argv[1:4]

with open("apps.json") as f:
    data = json.load(f)

app = next(a for a in data["apps"] if a["id"] == "kryoas-v2")
new_entry = {
    "version": version,
    "file": "fdroid/repo/KryoasControlStation64.apk",
    "description": description,
    "date": today,
}
app["versions"] = [v for v in app["versions"] if v["version"] != version]
app["versions"].insert(0, new_entry)

with open("apps.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"apps.json updated: kryoas-v2 -> {version}")
PYEOF

git add -A
git commit -m "Update KryoasControlStation64.apk and dashboard entry"
git config http.postBuffer 524288000
git push origin main

echo "Published. F-Droid index and https://latrics.github.io/kryoas-store/ dashboard both updated. Testers with 'Automatic update checks' enabled will see the update within a few hours, or immediately on manual refresh."
