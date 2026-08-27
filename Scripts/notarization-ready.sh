#!/bin/bash
#
# Rende un'app firmata pronta per la notarizzazione, e verifica che lo sia.
#
# Apple pretende che *ogni* eseguibile del bundle abbia l'hardened runtime e
# un timestamp sicuro, e rifiuta qualsiasi cosa porti `get-task-allow`. La
# fase di build firma già così l'albero ImageMagick, ma `xcodebuild
# -exportArchive` rifirma il bundle a modo suo: nel pacchetto App Store
# prodotto da Xcode Cloud `bin/magick` è uscito con flags=0x0, cioè senza
# hardened runtime. Per lo Store non conta, per la notarizzazione sì.
#
# Quindi qui non ci si limita a controllare: quello che manca viene rimesso,
# riusando gli entitlement che l'eseguibile ha già, così non si introduce una
# seconda verità su cosa dovrebbe dichiarare. Se il rimedio non basta, lo
# script si ferma prima di sprecare un giro di notarizzazione.
#
# Uso: notarization-ready.sh <Comprimio.app> <identità> [portachiavi]

set -euo pipefail

app=${1:?indica il bundle .app da controllare}
identity=${2:?indica una identità di firma}
keychain=${3:-}

keychain_args=()
[ -n "$keychain" ] && keychain_args=(--keychain "$keychain")
# bash 3.2 con `set -u` considera non definito un array vuoto: questa forma
# non espande niente quando l'array è vuoto, invece di far abortire lo script.
expand_keychain() { echo "${keychain_args[@]+"${keychain_args[@]}"}"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() { echo "::error::$*" >&2; exit 1; }

signature_info() { codesign --display --verbose=4 "$1" 2>&1 || true; }
has_runtime()    { grep -q "^CodeDirectory.*flags=.*runtime" <<< "$(signature_info "$1")"; }
has_timestamp()  { grep -q "^Timestamp=" <<< "$(signature_info "$1")"; }

# `machos` è tutto ciò che va firmato, `executables` il sottoinsieme che deve
# anche avere l'hardened runtime — quello riguarda i processi, non le
# librerie. La distinzione la fa il contenuto del file, non il nome né i
# permessi: i descrittori `.la` di libtool nell'albero ImageMagick hanno il
# bit di esecuzione e sono testo.
machos=()
executables=()
while IFS= read -r candidate; do
    kind=$(file -b "$candidate" 2>/dev/null || true)
    case "$kind" in
        *Mach-O*) machos+=("$candidate") ;;
        *) continue ;;
    esac
    case "$kind" in
        *Mach-O*executable*) executables+=("$candidate") ;;
    esac
done < <(find "$app" -type f)

# Un array vuoto sotto `set -u` darebbe un errore di bash incomprensibile
# invece del vero problema, che è un percorso sbagliato.
[ ${#machos[@]} -gt 0 ] || fail "nessun Mach-O trovato in $app"

echo "Mach-O nel bundle: ${#machos[@]} (di cui eseguibili: ${#executables[@]})"

# --- rimedio ---------------------------------------------------------------
# I nidificati per primi: rifirmare un eseguibile interno invalida la firma
# del bundle che lo contiene, quindi l'app va rifatta dopo, non prima.
resigned_nested=0
for executable in "${executables[@]}"; do
    [ "$executable" = "$app/Contents/MacOS/$(basename "${app%.app}")" ] && continue
    if has_runtime "$executable" && has_timestamp "$executable"; then continue
    fi
    echo "  rifirmo $(basename "$executable"): hardened runtime o timestamp mancante"
    entitlements="$work/$(basename "$executable").plist"
    if codesign -d --entitlements "$entitlements" --xml "$executable" 2>/dev/null \
       && [ -s "$entitlements" ]; then
        codesign --force --options runtime --timestamp \
            --entitlements "$entitlements" --sign "$identity" \
            $(expand_keychain) "$executable"
    else
        codesign --force --options runtime --timestamp --sign "$identity" \
            $(expand_keychain) "$executable"
    fi
    resigned_nested=$((resigned_nested + 1))
done

if [ "$resigned_nested" -gt 0 ]; then
    echo "  rifirmo il bundle: $resigned_nested eseguibili interni sono cambiati"
    entitlements="$work/app.plist"
    codesign -d --entitlements "$entitlements" --xml "$app" 2>/dev/null
    codesign --force --options runtime --timestamp \
        --entitlements "$entitlements" --sign "$identity" \
        $(expand_keychain) "$app"
fi

# --- verifica --------------------------------------------------------------
for executable in "${executables[@]}"; do
    name=$(basename "$executable")
    has_runtime "$executable"   || fail "$name senza hardened runtime"
    has_timestamp "$executable" || fail "$name senza timestamp sicuro"
done

# `get-task-allow` è ciò che rende un'app debuggabile, e la notarizzazione lo
# rifiuta: arriva quando si firma con un certificato di sviluppo invece che
# con il Developer ID.
app_entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null \
    | plutil -convert xml1 -o - - 2>/dev/null || true)
if grep -q "get-task-allow" <<< "$app_entitlements"; then
    fail "l'app dichiara get-task-allow: è stata firmata con un certificato di sviluppo"
fi

# Nessuna pipeline che possa chiudersi in anticipo sotto `pipefail`: si
# cattura tutto e si cerca dentro la stringa.
authority_of() {
    grep -m1 "^Authority=" <<< "$(signature_info "$1")" | cut -d= -f2- || true
}

authority=$(authority_of "$app")
case "$authority" in
    "Developer ID Application:"*) ;;
    *) fail "firmata da «${authority}», serve un «Developer ID Application»" ;;
esac

# Non basta che sia firmato il bundle: la notarizzazione guarda ogni pezzo di
# codice che contiene, e ne rifiuta uno firmato con un certificato di
# sviluppo o rimasto ad-hoc. Succede davvero — l'albero ImageMagick viene
# firmato dalla fase di build, che in una build locale usa un'identità
# diversa da quella di distribuzione.
intruders=0
for macho in "${machos[@]}"; do
    signer=$(authority_of "$macho")
    case "$signer" in
        "Developer ID Application:"*) continue ;;
    esac
    [ "$intruders" -lt 5 ] && echo "  firmato male: ${macho#"$app/"} → ${signer:-nessuna firma}"
    intruders=$((intruders + 1))
done
[ "$intruders" -gt 0 ] && fail "$intruders Mach-O non firmati con il Developer ID"

codesign --verify --deep --strict --verbose=1 "$app"

echo "Pronta per la notarizzazione: $authority"
