#!/bin/bash
# Usage: publish.sh /path/to/KryoasControlStation64.apk
# Copies a freshly signed release APK into the F-Droid repo, regenerates the
# index, and pushes it to GitHub Pages so testers get the update notification.
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 /path/to/signed-release.apk"
  exit 1
fi

APK_SRC="$1"
STORE_DIR="$HOME/kryoas-store"
FDROID_DIR="$STORE_DIR/fdroid"
JDK_BIN="$HOME/jdk/bin"
FDROID_BIN="$HOME/venv-fdroid/bin/fdroid"

export PATH="$JDK_BIN:$PATH"
export JAVA_HOME="$HOME/jdk"

if [ ! -f "$APK_SRC" ]; then
  echo "APK not found: $APK_SRC"
  exit 1
fi

cp "$APK_SRC" "$FDROID_DIR/repo/KryoasControlStation64.apk"

cd "$FDROID_DIR"
"$FDROID_BIN" update

cd "$STORE_DIR"
git add -A
git commit -m "Update KryoasControlStation64.apk"
git push origin main

echo "Published. Testers with 'Automatic update checks' enabled will see the update within a few hours, or immediately on manual refresh."
