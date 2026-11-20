#!/bin/bash
# Runs in its own WSL window (started by kryoas-release.sh) so the keystore
# password is typed here and never reaches a log or transcript.
#   sign-window.sh <status file> <unsigned1.apk> <signed1.apk> [<unsigned2.apk> <signed2.apk> ...]
# The password is asked once (hidden) and used for every APK in this run; it only
# lives in this window's process environment and is gone when the window closes.
# The status file gets "OK <cert sha256> ..." (one per APK) or "FAIL <reason>".
STATUS="$1"; shift
KS=~/keystores/kryoas-release.keystore
fail() { echo "FAIL $1" > "$STATUS"; read -p "$1. Press Enter to close"; exit 1; }
[ $# -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] || fail "bad arguments (need unsigned/signed pairs)"

echo "Kryoas release signing: $(( $# / 2 )) APK(s)"
PAIRS=("$@")
for ((i = 1; i < ${#PAIRS[@]}; i += 2)); do echo "  $(basename "${PAIRS[$i]}")"; done

CERTS=""
FIRST=1
while [ $# -gt 0 ]; do
  IN="$1"; OUTAPK="$2"; shift 2
  ALIGNED="${OUTAPK%.apk}-aligned.apk"
  rm -f "$OUTAPK" "$ALIGNED"
  zipalign -p -f 4 "$IN" "$ALIGNED" || fail "zipalign failed for $(basename "$IN")"
  SIGNED=0
  for TRY in 1 2 3; do
    if [ "$FIRST" = 1 ] || [ -z "${KRYOAS_KS_PASS:-}" ]; then
      echo
      read -r -s -p "Enter the store keystore password (attempt $TRY of 3): " KRYOAS_KS_PASS; echo
      export KRYOAS_KS_PASS
    fi
    if apksigner sign --ks "$KS" --ks-pass env:KRYOAS_KS_PASS --v2-signing-enabled true --v3-signing-enabled true \
         --out "$OUTAPK" "$ALIGNED"; then
      SIGNED=1; FIRST=0; break
    fi
    echo "Signing failed (see the message above; usually a mistyped password)."
    unset KRYOAS_KS_PASS
  done
  [ "$SIGNED" = 1 ] || { unset KRYOAS_KS_PASS; fail "apksigner failed 3 times"; }
  CERT=$(apksigner verify --print-certs "$OUTAPK" | grep -i "SHA-256" | grep -o "[0-9a-f]\{64\}" | head -1)
  rm -f "$ALIGNED" "$OUTAPK.idsig"
  echo "Signed $(basename "$OUTAPK")"
  CERTS="$CERTS $CERT"
done
unset KRYOAS_KS_PASS
echo "OK$CERTS" > "$STATUS"
echo "All signed. This window closes in 3 s."; sleep 3; exit 0
