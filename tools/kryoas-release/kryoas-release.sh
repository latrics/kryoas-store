#!/usr/bin/env bash
# kryoas-release: build, sign and publish a Kryoas app to the Kryoas store in one command.
# Phones with the in-app updater (KrayosAppUpdater) then offer the update by themselves.
#
#   kryoas-release <v1|v2> "release notes" [options]
#
# Options:
#   --dry-run       build + package + verify only; no signing, no publishing
#   --mandatory     users cannot postpone this update ("Later" hidden)
#   --code N        use this versionCode instead of "store/manifest + 1"
#   --skip-build    reuse the already built .so (packaging, signing and publishing still run)
#   -h | --help
#
# Run from Git Bash on the build PC. Signing opens a separate WSL window where you
# type the store keystore password (it never passes through this script).
set -euo pipefail

STORE_CERT_SHA256="9be7fdc07503d98fd51e68d76947bee0e89f807a63ce7f0a4995abfcf5c04d52"
RAW_BASE="https://raw.githubusercontent.com/latrics/kryoas-store/main"
NDK="C:/Users/pc/AppData/Local/Android/Sdk/ndk/21.3.6528147"
SDK="C:/Users/pc/AppData/Local/Android/Sdk"
BT="$SDK/build-tools/36.1.0"
ANDROIDDEPLOYQT="/c/Qt/5.15.2/android/bin/androiddeployqt.exe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="/c/Users/pc/kryoas-releases"          # unsigned/signed APKs + logs, kept per release

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ── Arguments ────────────────────────────────────────────────────────────────
VARIANT="${1:-}"; [ "$VARIANT" = "-h" ] || [ "$VARIANT" = "--help" ] && usage 0
[ $# -ge 2 ] || usage 1
NOTES="$2"; shift 2
DRY_RUN=0; MANDATORY=0; FORCE_CODE=""; SKIP_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --mandatory) MANDATORY=1 ;;
    --code) FORCE_CODE="$2"; shift ;;
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done

case "$VARIANT" in
  v1) REPO="/c/Users/pc/Kryoas-V1";               CHANNEL="kryoas-v1" ;;
  v2) REPO="/c/Users/pc/qgroundcontrol-v4.4.1";   CHANNEL="kryoas-v2" ;;
  *)  die "variant must be v1 or v2 (v3 has no repo set up for this tool yet)" ;;
esac
BUILD="$REPO/build/android-release-64"
MANIFEST="$REPO/android/AndroidManifest.xml"
SO="libKryoasControlStation_arm64-v8a.so"
[ -f "$BUILD/Makefile" ] || die "no build dir at $BUILD"
grep -q "android:value=\"$CHANNEL\"" "$MANIFEST" || die "$MANIFEST does not set update channel $CHANNEL"
grep -q "REQUEST_INSTALL_PACKAGES" "$MANIFEST" || die "$MANIFEST has no in-app updater (REQUEST_INSTALL_PACKAGES)"
[ -n "$NOTES" ] || die "release notes must not be empty"
export ANDROID_NDK_ROOT="$NDK" ANDROID_SDK_ROOT="$SDK" MSYS_NO_PATHCONV=1
unset KRYOAS_PLAY_BUILD   # store builds must keep the updater

# ── Version ──────────────────────────────────────────────────────────────────
step "Working out the version"
STORE_CODE=$(curl -fsS "$RAW_BASE/apps.json?t=$(date +%s)" | python -c "
import json,sys
a=[x for x in json.load(sys.stdin)['apps'] if x['id']=='$CHANNEL'][0]
print(max([int(v.get('versionCode',0)) for v in a['versions']]+[0]))")
MANIFEST_CODE=$(grep -o 'android:versionCode="[0-9]*"' "$MANIFEST" | grep -o '[0-9]*')
if [ -n "$FORCE_CODE" ]; then
  CODE="$FORCE_CODE"
else
  CODE=$(( (STORE_CODE > MANIFEST_CODE ? STORE_CODE : MANIFEST_CODE) + 1 ))
fi
[ "$CODE" -gt "$STORE_CODE" ] || die "versionCode $CODE is not above the store's $STORE_CODE"
# versionCode layout BB M I PP DDD (66 4 4 01 018) -> name 4.4.1-18
NAME="${CODE:2:1}.${CODE:3:1}.$((10#${CODE:4:2}))-$((10#${CODE:6:3}))"
echo "store $CHANNEL: $STORE_CODE   manifest: $MANIFEST_CODE   ->  release $NAME ($CODE)"
OUT="$WORK/$CHANNEL-$NAME"
mkdir -p "$OUT"

# ── Build ────────────────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" = 0 ]; then
  step "Building ($BUILD)"
  cd "$BUILD"
  # qmake does not re-run on its own; regenerate when a project file is newer.
  if [ -n "$(find "$REPO" -maxdepth 1 \( -name '*.pro' -o -name '*.pri' \) -newer Makefile)" ]; then
    echo "project files changed: re-running qmake"
    mingw32-make qmake > "$OUT/qmake.log" 2>&1 || { tail -20 "$OUT/qmake.log" || true; die "qmake failed"; }
  fi
  if ! mingw32-make -j8 > "$OUT/make.log" 2>&1; then
    { grep -E "error:|undefined reference|\*\*\*" "$OUT/make.log" | head -20; } || true
    die "build failed (log: $OUT/make.log)"
  fi
fi
[ -f "$BUILD/$SO" ] || die "$SO was not built"

# ── Package ──────────────────────────────────────────────────────────────────
step "Packaging $NAME"
# The build's post-link step rewrites the manifest version from git describe;
# set ours after it. The original is put back unless the release goes live.
cp "$MANIFEST" "$OUT/AndroidManifest.before.xml"
PUBLISHED=0
restore_manifest() { [ "$PUBLISHED" = 1 ] || cp "$OUT/AndroidManifest.before.xml" "$MANIFEST"; }
trap restore_manifest EXIT
sed -i -e "s/android:versionCode=\"[0-9]*\"/android:versionCode=\"$CODE\"/" \
       -e "s/android:versionName=\"[^\"]*\"/android:versionName=\"$NAME\"/" "$MANIFEST"
# make install from Git Bash writes to C:\C\Users\..., so copy the library by hand.
cp "$BUILD/$SO" "$BUILD/android-build/libs/arm64-v8a/$SO"
rm -rf "$BUILD/android-build/build/outputs/apk" \
       "$BUILD/android-build/build/intermediates/incremental/packageDebug" \
       "$BUILD/android-build/build/intermediates/incremental/packageRelease"
cd "$BUILD"
WINBUILD="$(cygpath -m "$BUILD")"
if ! "$ANDROIDDEPLOYQT" --input "$WINBUILD/android-KryoasControlStation-deployment-settings.json" \
       --output "$WINBUILD/android-build" --release --gradle > "$OUT/deploy.log" 2>&1; then
  tail -30 "$OUT/deploy.log" || true; die "androiddeployqt failed (log: $OUT/deploy.log)"
fi
UNSIGNED="$OUT/$CHANNEL-$NAME-unsigned.apk"
cp "$BUILD/android-build/build/outputs/apk/release/android-build-release-unsigned.apk" "$UNSIGNED"

# ── Verify the package ───────────────────────────────────────────────────────
step "Checking the APK"
UNSIGNED_W="$(cygpath -m "$UNSIGNED")"
BADGING=$("$BT/aapt.exe" dump badging "$UNSIGNED_W")
echo "$BADGING" | grep -q "versionCode='$CODE'"                      || die "APK versionCode is not $CODE"
echo "$BADGING" | grep -q "name='com.kryoas.controlstation'"         || die "APK package is wrong"
echo "$BADGING" | grep -q "REQUEST_INSTALL_PACKAGES"                 || die "APK lacks the in-app updater permission"
echo "$BADGING" | grep -q "application-debuggable"                   && die "APK is debuggable"
"$BT/aapt.exe" dump xmltree "$UNSIGNED_W" AndroidManifest.xml | grep -q "\"$CHANNEL\"" || die "APK channel is not $CHANNEL"
# Release packaging strips the library, so compare ELF build IDs, not file hashes.
READELF="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe"
unzip -p "$UNSIGNED" "lib/arm64-v8a/$SO" > "$OUT/apk-lib.so"
build_id() { "$READELF" -n "$(cygpath -m "$1")" | grep -o "Build ID: [0-9a-f]*" | cut -d' ' -f3; }
APK_SO_ID=$(build_id "$OUT/apk-lib.so"); BUILT_SO_ID=$(build_id "$BUILD/$SO")
rm -f "$OUT/apk-lib.so"
[ -n "$BUILT_SO_ID" ] && [ "$APK_SO_ID" = "$BUILT_SO_ID" ] || die "APK contains a stale $SO (build id ${APK_SO_ID:-none} vs ${BUILT_SO_ID:-none})"
echo "OK: $CHANNEL $NAME ($CODE), updater present, fresh native library, not debuggable"

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run: stopping before signing. Unsigned APK: $UNSIGNED"
  echo "(The manifest version was put back; nothing was signed or published.)"
  exit 0
fi

# ── Sign (separate window, password typed there) ─────────────────────────────
step "Signing: type the store keystore password in the WSL window that opens"
WSL_OUT="/mnt/c${OUT#/c}"
STATUS="$OUT/sign.status"
rm -f "$STATUS"
/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command "Start-Process wsl.exe -ArgumentList 'bash','/mnt/c${SCRIPT_DIR#/c}/sign-window.sh','$WSL_OUT/$CHANNEL-$NAME-unsigned.apk','$WSL_OUT/$CHANNEL-$NAME-signed.apk','$WSL_OUT/sign.status'"
for _ in $(seq 1 360); do [ -f "$STATUS" ] && grep -qE "^(OK|FAIL)" "$STATUS" && break; sleep 5; done
grep -q "^OK" "$STATUS" 2>/dev/null || die "signing did not finish ($(cat "$STATUS" 2>/dev/null || echo 'timed out after 30 min'))"
CERT=$(grep -o "[0-9a-f]\{64\}" "$STATUS" | head -1)
[ "$CERT" = "$STORE_CERT_SHA256" ] || die "signed with the wrong key ($CERT)"
SIGNED="$OUT/$CHANNEL-$NAME-signed.apk"
echo "Signed with the store key."

# ── Publish ──────────────────────────────────────────────────────────────────
step "Publishing to the Kryoas store"
WSL_SIGNED="$WSL_OUT/$CHANNEL-$NAME-signed.apk"
ENVS="GIT_TERMINAL_PROMPT=0"; [ "$MANDATORY" = 1 ] && ENVS="$ENVS MANDATORY=1"
printf '%s' "$NOTES" > "$OUT/notes.txt"
if [ "$VARIANT" = v2 ]; then
  wsl.exe bash -lc "cd ~/kryoas-store && git pull -q --rebase && env $ENVS ./publish.sh '$WSL_SIGNED' \"\$(cat '$WSL_OUT/notes.txt')\"" 2>&1 | grep -vE "^[0-9-]+ [0-9:,]+ INFO" | tail -15
else
  wsl.exe bash -lc "cd ~/kryoas-store && git pull -q --rebase && env $ENVS ./publish-app.sh $CHANNEL '$NAME' '$WSL_SIGNED' \"\$(cat '$WSL_OUT/notes.txt')\"" 2>&1 | tail -15
fi
AHEAD=$(wsl.exe bash -lc "cd ~/kryoas-store && git fetch -q && git log origin/main..HEAD --oneline | wc -l" | tr -d '\r')
if [ "$AHEAD" != "0" ]; then
  echo "Push did not go through; retrying with slow-link settings..."
  wsl.exe bash -lc "cd ~/kryoas-store && GIT_TERMINAL_PROMPT=0 git -c http.version=HTTP/1.1 -c http.lowSpeedTime=600 -c http.postBuffer=524288000 push origin main" \
    || die "push failed; the commit is in ~/kryoas-store, retry 'git push' there"
fi

# ── Verify live ──────────────────────────────────────────────────────────────
PUBLISHED=1   # the store commit exists from here on: keep the manifest in step with it
step "Checking the live store"
FILE=""
for _ in $(seq 1 40); do
  FILE=$(curl -fsS "$RAW_BASE/apps.json?t=$(date +%s)" | python -c "
import json,sys
v=[x for x in json.load(sys.stdin)['apps'] if x['id']=='$CHANNEL'][0]['versions'][0]
print(v['file'] if int(v.get('versionCode',0))==$CODE else '')") || true
  [ -n "$FILE" ] && break
  sleep 15
done
[ -n "$FILE" ] || die "apps.json on GitHub does not show $CODE after 10 min"
LIVE_SHA=$(curl -fsSL "$RAW_BASE/$FILE" | sha256sum | cut -d' ' -f1)
[ "$LIVE_SHA" = "$(sha256sum "$SIGNED" | cut -d' ' -f1)" ] || die "the live APK does not match the signed one"
PUBLISHED=1
echo "LIVE: $CHANNEL $NAME ($CODE)  $RAW_BASE/$FILE"
echo
echo "Phones on $CHANNEL with the updater will offer it on next launch/return to the app"
echo "(GitHub's cache can delay this ~5 min), or within 6 h in the background."
echo "Remember to commit $MANIFEST ($NAME / $CODE) in $REPO."
