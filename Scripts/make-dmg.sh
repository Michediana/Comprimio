#!/bin/bash
#
# Impacchetta l'app in un DMG con il collegamento ad Applications, che è il
# modo in cui su Mac ci si aspetta di installare qualcosa scaricato dal web.
#
# Il file system è HFS+ di proposito: un'immagine APFS non si monta sulle
# versioni di macOS più vecchie di quelle che Comprimio dichiara di
# supportare, e il DMG diventerebbe illeggibile proprio per chi ne ha più
# bisogno.
#
# Uso: make-dmg.sh <Comprimio.app> <destinazione.dmg>

set -euo pipefail

app=${1:?indica il bundle .app da impacchettare}
dmg=${2:?indica il percorso del DMG da creare}
name=$(basename "${app%.app}")

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# ditto e non cp: preserva attributi estesi e link simbolici del bundle, che
# `cp -R` può alterare quanto basta a invalidare la firma.
ditto "$app" "$staging/$(basename "$app")"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create \
    -volname "$name" \
    -srcfolder "$staging" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$dmg" > /dev/null

echo "DMG: $dmg ($(du -h "$dmg" | cut -f1))"
