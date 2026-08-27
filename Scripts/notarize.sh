#!/bin/bash
#
# Sottopone un artefatto alla notarizzazione e aspetta il verdetto.
#
# Ogni artefatto va notarizzato per conto suo: il ticket è legato all'hash di
# quello che si è caricato. Notarizzare l'app non copre il DMG che la
# contiene, e viceversa. Distribuendo un DMG servono entrambi i giri — l'app
# perché resti apribile anche se qualcuno la copia fuori dall'immagine e la
# lancia senza rete, il DMG perché Gatekeeper controlla anche l'immagine nel
# momento in cui viene montata.
#
# Uso: notarize.sh <app|dmg|pkg|zip> <chiave.p8> <key-id> <issuer-id>

set -euo pipefail

artifact=${1:?indica artefatto da notarizzare}
key=${2:?indica il file .p8}
key_id=${3:?indica il Key ID}
issuer=${4:?indica Issuer ID}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# notarytool non accetta un bundle: va impacchettato. ditto e non zip, che
# non conserva i link simbolici interni al bundle.
upload="$artifact"
if [ -d "$artifact" ]; then
    upload="$work/$(basename "$artifact").zip"
    ditto -c -k --keepParent "$artifact" "$upload"
fi

echo "Notarizzo $(basename "$artifact")…"
set +e
out=$(xcrun notarytool submit "$upload" \
    --key "$key" --key-id "$key_id" --issuer "$issuer" \
    --wait --timeout 30m 2>&1)
status=$?
set -e
echo "$out"

id=$(grep -m1 -E "^ *id: " <<< "$out" | awk '{print $2}' || true)

if [ $status -ne 0 ] || ! grep -q "status: Accepted" <<< "$out"; then
    echo "::error::notarizzazione respinta per $(basename "$artifact")"
    if [ -n "$id" ]; then
        echo "--- log di Apple ---"
        xcrun notarytool log "$id" --key "$key" --key-id "$key_id" --issuer "$issuer" || true
    fi
    exit 1
fi

# Il ticket va cucito dentro l'artefatto, altrimenti chi lo apre senza rete
# vede comunque l'avviso: Gatekeeper può chiedere conferma ad Apple solo se
# è online.
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
echo "Notarizzato e staplato: $(basename "$artifact")"
