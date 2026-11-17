#!/bin/bash
# Usage: publish-app.sh <app-id> <version> /path/to/signed.apk "description text"
# Adds a new version entry for one of the dashboard apps (apps.json) and
# publishes it: copies the APK in, updates apps.json, commits, pushes.
set -e

APP_ID="$1"
VERSION="$2"
APK_SRC="$3"
DESCRIPTION="$4"

if [ -z "$APP_ID" ] || [ -z "$VERSION" ] || [ -z "$APK_SRC" ] || [ -z "$DESCRIPTION" ]; then
  echo "Usage: $0 <app-id> <version> /path/to/signed.apk \"description text\""
  echo "  app-id must be one of: kryoas-v1, kryoas-v2, kryoas-v3"
  exit 1
fi

if [ ! -f "$APK_SRC" ]; then
  echo "APK not found: $APK_SRC"
  exit 1
fi

STORE_DIR="$HOME/kryoas-store"
PYTHON_BIN="$HOME/venv-fdroid/bin/python3"

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
"$PYTHON_BIN" - "$STORE_DIR/apps.json" "$APP_ID" "$VERSION_CODE" <<'PY'
import json, os, sys
path, app_id, code = sys.argv[1], sys.argv[2], int(sys.argv[3])
app = next((a for a in json.load(open(path))["apps"] if a["id"] == app_id), None)
newest = (app or {}).get("versions", [{}])[0] if app and app.get("versions") else {}
if int(newest.get("versionCode", 0)) >= code and os.environ.get("ALLOW_SAME_CODE") != "1":
    sys.exit(f"Refusing to publish: versionCode {code} is not higher than the current "
             f"{newest.get('versionCode')} ({newest.get('version')}); installed apps would never be "
             f"offered it. Bump the versionCode, or set ALLOW_SAME_CODE=1 to publish anyway.")
PY

STORE_DIR="$HOME/kryoas-store"
DEST_DIR="$STORE_DIR/apps/$APP_ID/$VERSION"
mkdir -p "$DEST_DIR"

BASENAME=$(basename "$APK_SRC")
cp "$APK_SRC" "$DEST_DIR/$BASENAME"

REL_PATH="apps/$APP_ID/$VERSION/$BASENAME"
TODAY=$(date +%F)

cd "$STORE_DIR"
"$PYTHON_BIN" - "$APP_ID" "$VERSION" "$REL_PATH" "$DESCRIPTION" "$TODAY" "$VERSION_CODE" "$APK_SHA256" "$APK_SIZE" <<'PYEOF'
import json, os, sys

app_id, version, rel_path, description, today, version_code, sha256, size = sys.argv[1:9]

with open("apps.json") as f:
    data = json.load(f)

app = next((a for a in data["apps"] if a["id"] == app_id), None)
if app is None:
    sys.exit(f"Unknown app id: {app_id} (edit apps.json to add it first)")

new_entry = {
    "version": version,
    "file": rel_path,
    "description": description,
    "date": today,
}
new_entry["versionCode"] = int(version_code)
new_entry["sha256"] = sha256
new_entry["size"] = int(size)
if os.environ.get("MANDATORY") == "1":
    app["minVersionCode"] = int(version_code)
    print(f"{app['id']}: marked mandatory (minVersionCode={version_code})")
# newest first, replacing any existing entry with the same version string
app["versions"] = [v for v in app["versions"] if v["version"] != version]
app["versions"].insert(0, new_entry)

with open("apps.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"apps.json updated: {app_id} {version} -> {rel_path}")
PYEOF

git add -A
git commit -m "Publish $APP_ID $VERSION"
git push

echo "Published $APP_ID $VERSION. Live at https://latrics.github.io/kryoas-store/ within a minute or two."
