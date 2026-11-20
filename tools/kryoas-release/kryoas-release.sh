#!/usr/bin/env bash
# kryoas-release: build, sign and publish Kryoas builds to the Kryoas store in one command.
# Phones with the in-app updater (KrayosAppUpdater) then offer the update by themselves.
#
#   kryoas-release <builds> "release notes" [options]
#
# <builds>  one or more of internal, internal-uin, client, client-uin, comma-separated,
#           or all-internal | all-client | all.   (See VERSIONING.md in the repo.)
#
# The version is kryoas-version.txt in the repo (edit it to bump). Every build in one
# run gets the same build number, worked out from the live store.
#
# Options:
#   --test               internal test build: version X.Y.Z-test.N (internal builds only)
#   --mandatory          users cannot postpone this update ("Later" hidden)
#   --dry-run            build + package + check only; no signing, publishing or tagging
#   --no-internal-first  allow a client release of a version no internal channel has had
#   --bridge             also publish client-uin to the old kryoas-v2 channel (one-time
#                        move of V2 phones onto client-uin)
#   -h | --help
#
# Run from Git Bash on the build PC. Signing opens a separate WSL window where you
# type the store keystore password once (it never passes through this script).
set -euo pipefail

STORE_CERT_SHA256="9be7fdc07503d98fd51e68d76947bee0e89f807a63ce7f0a4995abfcf5c04d52"
RAW_BASE="https://raw.githubusercontent.com/latrics/kryoas-store/main"
NDK="C:/Users/pc/AppData/Local/Android/Sdk/ndk/21.3.6528147"
SDK="C:/Users/pc/AppData/Local/Android/Sdk"
BT="$SDK/build-tools/36.1.0"
ANDROIDDEPLOYQT="/c/Qt/5.15.2/android/bin/androiddeployqt.exe"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="/c/Users/pc/kryoas-releases"          # APKs + logs, kept per release
REPO="${KRYOAS_REPO:-/c/Users/pc/qgroundcontrol-v4.4.1}"
BUILD="$REPO/build/android-release-64"
SO="libKryoasControlStation_arm64-v8a.so"
ALL_BUILDS="internal internal-uin client client-uin"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ── Arguments ────────────────────────────────────────────────────────────────
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && usage 0
[ $# -ge 2 ] || usage 1
BUILDS_ARG="$1"; NOTES="$2"; shift 2
TEST=0; MANDATORY=0; DRY_RUN=0; NO_INTERNAL_FIRST=0; BRIDGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --test) TEST=1 ;;
    --mandatory) MANDATORY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-internal-first) NO_INTERNAL_FIRST=1 ;;
    --bridge) BRIDGE=1 ;;
    -h|--help) usage 0 ;;
    *) die "unknown option $1" ;;
  esac
  shift
done
[ -n "$NOTES" ] || die "release notes must not be empty"

case "$BUILDS_ARG" in
  all)          BUILDS="$ALL_BUILDS" ;;
  all-internal) BUILDS="internal internal-uin" ;;
  all-client)   BUILDS="client client-uin" ;;
  *)            BUILDS="${BUILDS_ARG//,/ }" ;;
esac
HAS_CLIENT=0
for B in $BUILDS; do
  case " $ALL_BUILDS " in *" $B "*) ;; *) die "unknown build '$B' (use: $ALL_BUILDS)" ;; esac
  case "$B" in client*) HAS_CLIENT=1 ;; esac
done
[ "$TEST" = 1 ] && [ "$HAS_CLIENT" = 1 ] && die "--test is for internal builds only; clients only get plain versions"
if [ "$BRIDGE" = 1 ]; then
  case " $BUILDS " in *" client-uin "*) ;; *) die "--bridge needs client-uin in the builds" ;; esac
fi

[ -f "$BUILD/Makefile" ] || die "no build folder at $BUILD"
[ -f "$REPO/kryoas-version.txt" ] || die "$REPO/kryoas-version.txt is missing"
grep -q 'kryoasChannel' "$REPO/android/AndroidManifest.xml" || die "$REPO is not on the unified build system (manifest has no kryoasChannel placeholder)"
grep -q "REQUEST_INSTALL_PACKAGES" "$REPO/android/AndroidManifest.xml" || die "manifest has no in-app updater (REQUEST_INSTALL_PACKAGES)"
export ANDROID_NDK_ROOT="$NDK" ANDROID_SDK_ROOT="$SDK" MSYS_NO_PATHCONV=1
unset KRYOAS_PLAY_BUILD   # store builds must keep the updater

# ── Source tree ──────────────────────────────────────────────────────────────
step "Checking the source tree"
cd "$REPO"
BRANCH=$(git rev-parse --abbrev-ref HEAD); COMMIT=$(git rev-parse --short=7 HEAD)
CHANGES=$(git status --porcelain --untracked-files=no --ignore-submodules)
echo "$REPO  branch $BRANCH  commit $COMMIT"
if [ -n "$CHANGES" ]; then
  if [ "$HAS_CLIENT" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    die "uncommitted changes; client releases must be built from a commit:
$CHANGES"
  fi
  echo "WARNING: uncommitted changes (allowed for internal builds; the app shows +changes)"
fi
if [ "$HAS_CLIENT" = 1 ] && [ "$BRANCH" != main ]; then
  echo "WARNING: client release from branch $BRANCH, not main"
fi

# ── Version ──────────────────────────────────────────────────────────────────
step "Working out the version"
VERSION=$(tr -d ' \r\n' < "$REPO/kryoas-version.txt")
[[ "$VERSION" =~ ^(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$ ]] || die "kryoas-version.txt must be MAJOR.MINOR.PATCH (each 0-99), got '$VERSION'"
MAJ=${BASH_REMATCH[1]}; MIN=${BASH_REMATCH[2]}; PAT=${BASH_REMATCH[3]}
BASE=$(( 1000000000 + MAJ*10000000 + MIN*100000 + PAT*1000 ))
APPS_JSON=$(curl -fsS "$RAW_BASE/apps.json?t=$(date +%s)") || die "cannot read the store's apps.json"
CHANNELS="$BUILDS"; [ "$BRIDGE" = 1 ] && CHANNELS="$CHANNELS kryoas-v2"
# Prints the next build number, then INTERNAL_HAD=0|1, then one line per problem.
CHECK=$(printf '%s' "$APPS_JSON" | python -c "
import json, sys
apps = {a['id']: a for a in json.load(sys.stdin)['apps']}
base, version, test, channels = $BASE, '$VERSION', $TEST, '$CHANNELS'.split()
codes = [int(v.get('versionCode', 0)) for a in apps.values() for v in a.get('versions', [])]
used = [c - base for c in codes if base <= c < base + 1000]
print(max(used + [0]) + 1)
internal = [v.get('version', '') for ch in ('internal', 'internal-uin') if ch in apps for v in apps[ch].get('versions', [])]
print('INTERNAL_HAD=' + ('1' if any(x == version or x.startswith(version + '-test.') for x in internal) else '0'))
for ch in channels:
    if ch not in apps:
        print(f'store has no channel {ch} (add it to apps.json first, see VERSIONING.md)')
        continue
    if not test and any(v.get('version') == version for v in apps[ch].get('versions', [])):
        print(f'{ch} already has {version}; bump kryoas-version.txt (a fix is a PATCH bump)')
    top = max([int(v.get('versionCode', 0)) for v in apps[ch].get('versions', [])] + [0])
    if top >= base + 1000:
        print(f'{ch} already has a newer version (versionCode {top}) than {version}')
")
BUILD_NO=$(echo "$CHECK" | sed -n 1p)
INTERNAL_HAD=$(echo "$CHECK" | sed -n 2p | cut -d= -f2)
PROBLEMS=$(echo "$CHECK" | sed '1,2d')
if [ "$DRY_RUN" = 1 ]; then   # nothing is published: a channel can still be missing
  PROBLEMS=$(echo "$PROBLEMS" | grep -v '^store has no channel' || true)
fi
[ -z "$PROBLEMS" ] || die "$PROBLEMS"
[ "$BUILD_NO" -le 999 ] || die "build number $BUILD_NO is over 999 for $VERSION; bump kryoas-version.txt"
if [ "$HAS_CLIENT" = 1 ] && [ "$INTERNAL_HAD" = 0 ] && [ "$NO_INTERNAL_FIRST" = 0 ]; then
  die "no internal channel has had $VERSION (or a test of it). Release it to internal first, or pass --no-internal-first"
fi
CODE=$(( BASE + BUILD_NO ))
if [ "$TEST" = 1 ]; then NAME="$VERSION-test.$BUILD_NO"; else NAME="$VERSION"; fi
echo "Version $NAME  build $BUILD_NO  versionCode $CODE  builds: $BUILDS"
# A final release needs its CHANGELOG.md section (that is what pilots are told changed).
if [ "$TEST" = 0 ] && ! grep -q "^## ${VERSION//./\\.}\b" "$REPO/CHANGELOG.md" 2>/dev/null; then
  die "CHANGELOG.md has no '## $VERSION' section. Add what changed in $VERSION (tagged by app) and commit first."
fi

# What each APK will contain (FEATURES.md is generated from the feature table).
step "Features per build (FEATURES.md)"
[ -f "$REPO/FEATURES.md" ] || die "$REPO/FEATURES.md is missing"
for B in $BUILDS; do
  # fields: $1 is empty (line starts with |), $2 the feature, $3..$6 the four apps
  case "$B" in internal) COL=3 ;; internal-uin) COL=4 ;; client) COL=5 ;; client-uin) COL=6 ;; esac
  FEATS=$(awk -F'|' -v c="$COL" '/^\| Feature \|/{t=1; next} t && /^\|---/{next} t && /^\|/{f=$2; v=$c; gsub(/^ +| +$/,"",f); gsub(/^ +| +$/,"",v); if (v ~ /^since/) printf "%s%s (%s)", (n++ ? ", " : ""), f, v} t && !/^\|/{exit}' "$REPO/FEATURES.md")
  printf '  %-13s %s\n' "$B:" "${FEATS:-standard set only}"
done
OUT="$WORK/kryoas-$NAME"
mkdir -p "$OUT"

app_id_for() { case "$1" in client*) echo com.kryoas.controlstation ;; *) echo com.kryoas.controlstation.internal ;; esac; }
label_for()  { case "$1" in client*) echo "Kryoas" ;; *) echo "Kryoas Internal" ;; esac; }

# ── Build, package and check each build ──────────────────────────────────────
WINBUILD="$(cygpath -m "$BUILD")"
READELF="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-readelf.exe"
build_id() { "$READELF" -n "$(cygpath -m "$1")" | grep -o "Build ID: [0-9a-f]*" | cut -d' ' -f3; }
for B in $BUILDS; do
  step "Building $B $NAME"
  export KRYOAS_TRACK="${B%-uin}" KRYOAS_BUILD="$BUILD_NO" KRYOAS_TEST="$TEST"
  case "$B" in *-uin) export KRYOAS_UIN=1 ;; *) export KRYOAS_UIN=0 ;; esac
  cd "$BUILD"
  # Always re-run qmake: the build identity is read there (only KryoasBuildInfo.cc recompiles).
  mingw32-make qmake > "$OUT/$B-qmake.log" 2>&1 || { tail -20 "$OUT/$B-qmake.log"; die "qmake failed for $B"; }
  grep -q "^kryoas.channel=$B\$" "$BUILD/kryoas-build.properties" || die "qmake did not write the $B identity (see $OUT/$B-qmake.log)"
  grep -q "^kryoas.versionCode=$CODE\$" "$BUILD/kryoas-build.properties" || die "qmake versionCode is not $CODE"
  if ! mingw32-make -j8 > "$OUT/$B-make.log" 2>&1; then
    { grep -E "error:|undefined reference|\*\*\*" "$OUT/$B-make.log" | head -20; } || true
    die "build failed for $B (log: $OUT/$B-make.log)"
  fi
  [ -f "$BUILD/$SO" ] || die "$SO was not built"

  # make install from Git Bash writes to C:\C\Users\..., so copy the library by hand.
  cp "$BUILD/$SO" "$BUILD/android-build/libs/arm64-v8a/$SO"
  rm -rf "$BUILD/android-build/build/outputs/apk" \
         "$BUILD/android-build/build/intermediates/incremental/packageDebug" \
         "$BUILD/android-build/build/intermediates/incremental/packageRelease"
  if ! "$ANDROIDDEPLOYQT" --input "$WINBUILD/android-KryoasControlStation-deployment-settings.json" \
         --output "$WINBUILD/android-build" --release --gradle > "$OUT/$B-deploy.log" 2>&1; then
    tail -30 "$OUT/$B-deploy.log" || true; die "androiddeployqt failed for $B (log: $OUT/$B-deploy.log)"
  fi
  UNSIGNED="$OUT/kryoas-$B-$NAME-unsigned.apk"
  cp "$BUILD/android-build/build/outputs/apk/release/android-build-release-unsigned.apk" "$UNSIGNED"

  UNSIGNED_W="$(cygpath -m "$UNSIGNED")"
  BADGING=$("$BT/aapt.exe" dump badging "$UNSIGNED_W")
  echo "$BADGING" | grep -q "package: name='$(app_id_for "$B")' versionCode='$CODE' versionName='$NAME'" \
                                                     || die "$B: APK package/version is not $(app_id_for "$B") $CODE $NAME"
  echo "$BADGING" | grep -q "application-label:'$(label_for "$B")'" || die "$B: APK label is not '$(label_for "$B")'"
  echo "$BADGING" | grep -q "REQUEST_INSTALL_PACKAGES"             || die "$B: APK lacks the in-app updater permission"
  if echo "$BADGING" | grep -q "application-debuggable"; then die "$B: APK is debuggable"; fi
  "$BT/aapt.exe" dump xmltree "$UNSIGNED_W" AndroidManifest.xml | grep -q "\"$B\" (Raw" || die "$B: APK channel is not $B"
  # Release packaging strips the library, so compare ELF build IDs, not file hashes.
  unzip -p "$UNSIGNED" "lib/arm64-v8a/$SO" > "$OUT/apk-lib.so"
  APK_SO_ID=$(build_id "$OUT/apk-lib.so"); BUILT_SO_ID=$(build_id "$BUILD/$SO"); rm -f "$OUT/apk-lib.so"
  [ -n "$BUILT_SO_ID" ] && [ "$APK_SO_ID" = "$BUILT_SO_ID" ] || die "$B: APK contains a stale $SO"
  echo "OK: $B $NAME ($CODE) $(app_id_for "$B"), channel $B, updater present, fresh library, not debuggable"
done
unset KRYOAS_TRACK KRYOAS_UIN KRYOAS_BUILD KRYOAS_TEST

if [ "$DRY_RUN" = 1 ]; then
  step "Dry run: stopping before signing. Unsigned APKs are in $OUT"
  exit 0
fi

# ── Sign all APKs in one window (password typed there, once) ─────────────────
step "Signing: type the store keystore password in the WSL window that opens"
WSL_OUT="/mnt/c${OUT#/c}"
STATUS="$OUT/sign.status"; rm -f "$STATUS"
SIGN_ARGS="'$WSL_OUT/sign.status'"
for B in $BUILDS; do
  SIGN_ARGS="$SIGN_ARGS,'$WSL_OUT/kryoas-$B-$NAME-unsigned.apk','$WSL_OUT/kryoas-$B-$NAME.apk'"
done
/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe -NoProfile -Command \
  "Start-Process wsl.exe -ArgumentList 'bash','/mnt/c${SCRIPT_DIR#/c}/sign-window.sh',$SIGN_ARGS"
for _ in $(seq 1 360); do [ -f "$STATUS" ] && grep -qE "^(OK|FAIL)" "$STATUS" && break; sleep 5; done
grep -q "^OK" "$STATUS" 2>/dev/null || die "signing did not finish ($(cat "$STATUS" 2>/dev/null || echo 'timed out after 30 min'))"
for CERT in $(grep -o "[0-9a-f]\{64\}" "$STATUS"); do
  [ "$CERT" = "$STORE_CERT_SHA256" ] || die "an APK was signed with the wrong key ($CERT)"
done
for B in $BUILDS; do [ -f "$OUT/kryoas-$B-$NAME.apk" ] || die "signed APK for $B is missing"; done
echo "All APKs signed with the store key."

# ── Publish ──────────────────────────────────────────────────────────────────
printf '%s' "$NOTES" > "$OUT/notes.txt"
ENVS="GIT_TERMINAL_PROMPT=0"; [ "$MANDATORY" = 1 ] && ENVS="$ENVS MANDATORY=1"
publish() {   # <channel> <apk file name>
  step "Publishing $2 to channel $1"
  wsl.exe bash -lc "cd ~/kryoas-store && git pull -q --rebase && env $ENVS ./publish-app.sh '$1' '$NAME' '$WSL_OUT/$2' \"\$(cat '$WSL_OUT/notes.txt')\"" 2>&1 | tail -6
  AHEAD=$(wsl.exe bash -lc "cd ~/kryoas-store && git fetch -q && git log origin/main..HEAD --oneline | wc -l" | tr -d '\r')
  if [ "$AHEAD" != "0" ]; then
    echo "Push did not go through; retrying with slow-link settings..."
    wsl.exe bash -lc "cd ~/kryoas-store && GIT_TERMINAL_PROMPT=0 git -c http.version=HTTP/1.1 -c http.lowSpeedTime=600 -c http.postBuffer=524288000 push origin main" \
      || die "push failed; the commit is in ~/kryoas-store, retry 'git push' there"
  fi
}
verify_live() {   # <channel> <apk file name>
  local FILE=""
  for _ in $(seq 1 40); do
    FILE=$(curl -fsS "$RAW_BASE/apps.json?t=$(date +%s)" | python -c "
import json,sys
v=[x for x in json.load(sys.stdin)['apps'] if x['id']=='$1'][0]['versions'][0]
print(v['file'] if int(v.get('versionCode',0))==$CODE else '')") || true
    [ -n "$FILE" ] && break
    sleep 15
  done
  [ -n "$FILE" ] || die "apps.json on GitHub does not show $CODE for $1 after 10 min"
  LIVE_SHA=$(curl -fsSL "$RAW_BASE/$FILE" | sha256sum | cut -d' ' -f1)
  [ "$LIVE_SHA" = "$(sha256sum "$OUT/$2" | cut -d' ' -f1)" ] || die "the live APK on $1 does not match the signed one"
  echo "LIVE: $1 $NAME ($CODE)  $RAW_BASE/$FILE"
}
for B in $BUILDS; do publish "$B" "kryoas-$B-$NAME.apk"; done
if [ "$BRIDGE" = 1 ]; then publish kryoas-v2 "kryoas-client-uin-$NAME.apk"; fi

step "Checking the live store"
for B in $BUILDS; do verify_live "$B" "kryoas-$B-$NAME.apk"; done
if [ "$BRIDGE" = 1 ]; then verify_live kryoas-v2 "kryoas-client-uin-$NAME.apk"; fi

# ── Tag ──────────────────────────────────────────────────────────────────────
TAG="kryoas-$NAME"
# MSYS_NO_PATHCONV=1 (set for the Android tools) stops Git Bash turning /c/...
# into C:/..., so run git from inside the repo instead of git -C "$REPO".
cd "$REPO"
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
  echo "Tag $TAG already exists (an earlier release of this version); not moved."
else
  git tag -a "$TAG" -m "Kryoas $NAME ($CODE): $BUILDS" "$COMMIT"
  echo "Tagged $COMMIT as $TAG (local; push it with: git push origin $TAG)"
fi
echo
echo "Phones on these channels with the updater will offer it on next launch/return to the app"
echo "(GitHub's cache can delay this ~5 min), or within 6 h in the background."
if [ "$TEST" = 0 ]; then
  echo
  echo "Once every app that should get $VERSION has it: date its CHANGELOG.md section and bump"
  echo "kryoas-version.txt on main to the next version with a new section (VERSIONING.md)."
fi
