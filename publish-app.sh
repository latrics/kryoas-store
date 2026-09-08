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
DEST_DIR="$STORE_DIR/apps/$APP_ID/$VERSION"
mkdir -p "$DEST_DIR"

BASENAME=$(basename "$APK_SRC")
cp "$APK_SRC" "$DEST_DIR/$BASENAME"

REL_PATH="apps/$APP_ID/$VERSION/$BASENAME"
TODAY=$(date +%F)

cd "$STORE_DIR"
python3 - "$APP_ID" "$VERSION" "$REL_PATH" "$DESCRIPTION" "$TODAY" <<'PYEOF'
import json, sys

app_id, version, rel_path, description, today = sys.argv[1:6]

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
