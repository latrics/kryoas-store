#!/bin/bash
# Runs in its own WSL window (started by kryoas-release.sh) so the keystore
# password is typed here and never reaches a log or transcript.
#   sign-window.sh <unsigned.apk> <signed.apk> <status file>
IN="$1"; OUTAPK="$2"; STATUS="$3"
ALIGNED="${OUTAPK%.apk}-aligned.apk"
KS=~/keystores/kryoas-release.keystore
echo "Kryoas release signing: $(basename "$OUTAPK")"
rm -f "$OUTAPK" "$ALIGNED"
if ! zipalign -p -f 4 "$IN" "$ALIGNED"; then
  echo "FAIL zipalign" > "$STATUS"; read -p "zipalign failed. Press Enter to close"; exit 1
fi
for TRY in 1 2 3; do
  echo
  echo "Enter the store keystore password (attempt $TRY of 3):"
  if apksigner sign --ks "$KS" --v2-signing-enabled true --v3-signing-enabled true --out "$OUTAPK" "$ALIGNED"; then
    CERT=$(apksigner verify --print-certs "$OUTAPK" | grep -i "SHA-256" | grep -o "[0-9a-f]\{64\}" | head -1)
    rm -f "$ALIGNED" "$OUTAPK.idsig"
    echo "OK $CERT" > "$STATUS"
    echo "Signed. This window closes in 3 s."; sleep 3; exit 0
  fi
  echo "Signing failed (see the message above; usually a mistyped password)."
done
echo "FAIL apksigner (3 attempts)" > "$STATUS"
read -p "Giving up after 3 attempts. Press Enter to close"
exit 1
