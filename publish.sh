#!/bin/bash
# Usage: publish.sh /path/to/signed-release.apk ["description text"]
# Copies a freshly signed release APK into the F-Droid repo, regenerates the
# index, updates the dashboard's V2 (client / MAVLink signing) entry to match,
# and pushes it all to GitHub Pages so testers get the update notification.
set -e

# RETIRED with Kryoas 1.0.0 (see README.md). This was the pre-1.0 V2 flow: it
# overwrites the one shared fdroid/repo/KryoasControlStation64.apk and the
# kryoas-v2 entry. Releases now go through kryoas-release, which runs
# publish-app.sh for each build's channel (and --bridge for kryoas-v2).
# The F-Droid repo stays online as it is. Emergency only: KRYOAS_LEGACY_FDROID=1.
if [ "${KRYOAS_LEGACY_FDROID:-}" != "1" ]; then
  echo "publish.sh is retired. Use kryoas-release, or ./publish-app.sh <channel> <version> <apk> \"notes\"." >&2
  echo "Channels: internal, internal-uin, client, client-uin (see README.md)." >&2
  exit 1
fi

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

# ── In-app updater metadata ───────────────────────────────────────────────
# KrayosAppUpdater.java (in the app) only offers a version whose apps.json
# entry has versionCode + sha256, and only if versionCode is higher than the
# installed one. Checked before anything in the store is touched.
#   MANDATORY=1        users cannot postpone this update ("Later" is hidden)
#   ALLOW_SAME_CODE=1  publish even if the versionCode is not higher
APK_META=$("$PYTHON_BIN" - "$APK_SRC" <<'PY' 2>/dev/null
import sys
from androguard.core.apk import APK
a = APK(sys.argv[1])
print(a.get_androidversion_code(), a.get_package())
PY
)
VERSION_CODE=$(echo "$APK_META" | awk '{print $1}')
APK_PACKAGE=$(echo "$APK_META" | awk '{print $2}')
APK_SHA256=$(sha256sum "$APK_SRC" | cut -d' ' -f1)
APK_SIZE=$(stat -c%s "$APK_SRC")
if [ -z "$VERSION_CODE" ]; then
  echo "Could not read versionCode from the APK (androguard)."; exit 1
fi
echo "APK $APK_PACKAGE versionCode $VERSION_CODE sha256 $APK_SHA256 size $APK_SIZE"
"$PYTHON_BIN" - "$STORE_DIR/apps.json" "kryoas-v2" "$VERSION_CODE" <<'PY'
import json, os, sys
path, app_id, code = sys.argv[1], sys.argv[2], int(sys.argv[3])
app = next((a for a in json.load(open(path))["apps"] if a["id"] == app_id), None)
newest = (app or {}).get("versions", [{}])[0] if app and app.get("versions") else {}
if int(newest.get("versionCode", 0)) >= code and os.environ.get("ALLOW_SAME_CODE") != "1":
    sys.exit(f"Refusing to publish: versionCode {code} is not higher than the current "
             f"{newest.get('versionCode')} ({newest.get('version')}); installed apps would never be "
             f"offered it. Bump the versionCode, or set ALLOW_SAME_CODE=1 to publish anyway.")
PY

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
"$PYTHON_BIN" - "$VERSION_NAME" "$DESCRIPTION" "$TODAY" "$VERSION_CODE" "$APK_SHA256" "$APK_SIZE" <<'PYEOF'
import json, os, sys

version, description, today, version_code, sha256, size = sys.argv[1:7]

with open("apps.json") as f:
    data = json.load(f)

app = next(a for a in data["apps"] if a["id"] == "kryoas-v2")
new_entry = {
    "version": version,
    "file": "fdroid/repo/KryoasControlStation64.apk",
    "description": description,
    "date": today,
}
new_entry["versionCode"] = int(version_code)
new_entry["sha256"] = sha256
new_entry["size"] = int(size)
if os.environ.get("MANDATORY") == "1":
    app["minVersionCode"] = int(version_code)
    print(f"{app['id']}: marked mandatory (minVersionCode={version_code})")
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
