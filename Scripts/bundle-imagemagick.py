#!/usr/bin/env python3
"""
Copia ImageMagick dentro il bundle dell'app, rendendolo rilocabile.

Prende l'installazione presente sulla macchina di build (Homebrew, MacPorts
o un prefisso indicato con IMAGEMAGICK_PREFIX), copia il binario `magick`,
la chiusura delle librerie da cui dipende e i moduli coder, poi riscrive
gli install name in forma relativa a `@loader_path`: l'app risultante non
dipende più da /opt/homebrew.

Struttura prodotta sotto Contents/Resources/ImageMagick:

    bin/magick
    lib/*.dylib                                   librerie proprie e di terze parti
    lib/ImageMagick*/modules-*/{coders,filters}/   moduli caricabili (.la + .so)
    etc/ImageMagick-7/, share/ImageMagick-7/,
    lib/ImageMagick*/config-*/                    file di configurazione
    imagemagick-bundle.json                       manifest letto dall'app

Due modalità:

    bundle-imagemagick.py vendor <cartella-vendor>
        Costruisce l'albero rilocabile partendo da un'installazione locale
        (Homebrew, MacPorts, IMAGEMAGICK_PREFIX) e lo scrive in
        <cartella-vendor>/<architettura>. Si lancia a mano, solo quando si
        aggiorna ImageMagick, e il risultato si committa: firma ad-hoc, così
        i byte non dipendono dall'identità di chi lo costruisce.

    bundle-imagemagick.py install <cartella-vendor> <destinazione>
        Copia l'albero versionato dentro l'app e lo rifirma con l'identità
        della macchina che compila. È quello che esegue la fase di build:
        non tocca Homebrew, quindi compilare non richiede alcuna
        installazione di ImageMagick.

Ogni architettura è un albero a sé, generato sulla macchina corrispondente:
ImageMagick si installa come binario nativo, e non esiste un modo pratico di
produrre l'albero arm64 da un Mac Intel o viceversa. La fase di build sceglie
in base ad ARCHS: una sola architettura viene copiata così com'è, più di una
vengono fuse con lipo in un albero universale.
"""

import glob
import json
import os
import platform
import re
import shutil
import subprocess
import sys

STAMP = ".comprimio-bundle-stamp"

# Coder che la formula `imagemagick` di Homebrew non compila, perché non
# dipende da jpeg-xl, openjpeg, openexr né libraw. `imagemagick-full` è la
# stessa identica versione con quelle dipendenze: da lì si prendono i moduli
# che mancano, e soltanto quelli.
#
# Prendere l'intero albero di imagemagick-full costerebbe il doppio in peso e
# soprattutto porterebbe libgs: pdf.so e ps.so di quella formula ci sono
# linkati, e Ghostscript è AGPL. Innestando i singoli moduli, PDF e PostScript
# restano quelli della formula normale, che scrivono senza Ghostscript.
EXTRA_CODERS = ("jxl", "jp2", "exr", "dng")

# Le librerie di sistema restano dove sono: sono garantite su ogni Mac.
SYSTEM_PREFIXES = ("/usr/lib", "/System")

MACHO_MAGIC = (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe")


def log(message):
    print(f"[bundle-imagemagick] {message}")


# --- individuazione dell'installazione di partenza ------------------------

def find_source_prefix():
    """Restituisce (prefix, magick) dell'installazione da copiare."""
    candidates = []
    explicit = os.environ.get("IMAGEMAGICK_PREFIX")
    if explicit:
        candidates.append(os.path.join(explicit, "bin", "magick"))
    candidates += [
        "/opt/homebrew/bin/magick",
        "/usr/local/bin/magick",
        "/opt/local/bin/magick",
    ]
    found = shutil.which("magick")
    if found:
        candidates.append(found)

    for candidate in candidates:
        if candidate and os.path.exists(candidate):
            real = os.path.realpath(candidate)
            return os.path.dirname(os.path.dirname(real)), real
    return None, None


def magick_version(magick):
    out = subprocess.run([magick, "-version"], capture_output=True, text=True).stdout
    match = re.search(r"ImageMagick (\d+\.\d+\.\d+)", out)
    if not match:
        raise SystemExit("Impossibile leggere la versione di ImageMagick.")
    return match.group(1)


def find_extra_prefix():
    """
    Installazione da cui prendere i coder di EXTRA_CODERS, se c'è. Si indica
    con IMAGEMAGICK_EXTRA_PREFIX, altrimenti si cerca imagemagick-full: è
    keg-only, quindi sta nel suo prefisso e non si vede da bin/magick.
    """
    explicit = os.environ.get("IMAGEMAGICK_EXTRA_PREFIX")
    candidates = [explicit] if explicit else []
    candidates += [
        "/opt/homebrew/opt/imagemagick-full",
        "/usr/local/opt/imagemagick-full",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(os.path.join(candidate, "bin", "magick")):
            return candidate
    return None


def graft_extra_coders(prefix, version, coders_dir):
    """
    Copia i moduli di EXTRA_CODERS dentro l'albero in costruzione e restituisce
    le coppie (sorgente, copia). Le librerie di cui hanno bisogno le porta la
    chiusura, come per ogni altro modulo.

    La versione deve coincidere: un modulo si lega a MagickCore per simboli e
    strutture, e montarne uno compilato contro una versione diversa non dà un
    errore in fase di innesto — dà un formato che a runtime non si registra,
    o peggio si registra e sbaglia i conti.
    """
    extra_version = magick_version(os.path.join(prefix, "bin", "magick"))
    if extra_version != version:
        raise SystemExit(
            f"Versioni diverse: l'albero è ImageMagick {version}, "
            f"{prefix} è {extra_version}. Allineale prima di innestare i coder "
            f"(brew upgrade imagemagick imagemagick-full)."
        )
    source_dir = find_modules_dir(prefix)
    if not source_dir:
        raise SystemExit(f"Nessuna cartella di moduli in {prefix}.")

    def replace(source, copy):
        # Un modulo può esserci già (dng.so c'è, ma senza libraw) e Homebrew lo
        # installa in sola lettura: sovrascriverlo di netto fallirebbe.
        if os.path.exists(copy):
            os.remove(copy)
        shutil.copy2(source, copy)

    grafted = []
    for name in EXTRA_CODERS:
        source = os.path.join(source_dir, "coders", f"{name}.so")
        if not os.path.exists(source):
            raise SystemExit(f"Modulo {name}.so assente da {source_dir}/coders.")
        copy = os.path.join(coders_dir, f"{name}.so")
        replace(source, copy)
        # Il .la è il descrittore con cui ltdl trova il .so: senza, il modulo
        # non viene nemmeno cercato.
        la = os.path.join(source_dir, "coders", f"{name}.la")
        if os.path.exists(la):
            replace(la, os.path.join(coders_dir, f"{name}.la"))
        grafted.append((source, copy))
    return grafted


def find_modules_dir(prefix):
    """
    Cartella dei moduli caricabili. Va cercata sul filesystem: il quantum nel
    percorso (modules-Q16HDRI) non coincide con quello stampato da
    `magick -version` (Q16-HDRI), quindi non si può ricostruire a mano.
    """
    for match in sorted(glob.glob(os.path.join(prefix, "lib", "ImageMagick*", "modules-*"))):
        if os.path.isdir(match):
            return match
    return None


# --- analisi Mach-O -------------------------------------------------------

def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    try:
        with open(path, "rb") as handle:
            return handle.read(4) in MACHO_MAGIC
    except OSError:
        return False


def load_commands(path):
    return subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout


def rpaths(path):
    """LC_RPATH del binario, con @loader_path/@executable_path espansi."""
    result = []
    lines = load_commands(path).splitlines()
    for index, line in enumerate(lines):
        if "cmd LC_RPATH" not in line:
            continue
        for candidate in lines[index:index + 4]:
            match = re.search(r"^\s*path (.+?) \(offset", candidate)
            if match:
                value = match.group(1)
                owner = os.path.dirname(path)
                value = value.replace("@loader_path", owner).replace("@executable_path", owner)
                result.append(os.path.normpath(value))
                break
    return result


def linked_libraries(path):
    """
    Nomi così come sono scritti nel Mach-O, install name incluso.

    Su un file fat `otool -L` intercala un'intestazione per architettura
    («file (architecture arm64):»), che non è una dipendenza. Le righe delle
    librerie sono le uniche indentate: le altre si scartano.
    """
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    return [line.strip().split(" (")[0]
            for line in out.splitlines()[1:]
            if line.startswith((" ", "\t")) and line.strip()]


# Pool di LC_RPATH raccolti da tutti i Mach-O esaminati. Serve perché dyld
# risolve @rpath usando gli rpath di *tutta* la catena di caricamento, non
# solo quelli della libreria che dichiara la dipendenza: libtiff, per
# esempio, chiede @rpath/libwebp.7.dylib senza avere alcun LC_RPATH.
RPATH_POOL = []

SEARCH_ROOTS = ("/opt/homebrew", "/usr/local", "/opt/local")


def remember_rpaths(path):
    for base in rpaths(path):
        if base not in RPATH_POOL:
            RPATH_POOL.append(base)


def find_by_leaf(leaf):
    """Ultima risorsa: cerca la libreria nei prefissi dei gestori di pacchetti."""
    for root in SEARCH_ROOTS:
        for pattern in (f"{root}/opt/*/lib/{leaf}", f"{root}/lib/{leaf}"):
            for match in glob.glob(pattern):
                if os.path.exists(match):
                    return os.path.realpath(match)
    return None


def resolve(reference, referrer):
    """
    Percorso reale di una dipendenza. Gestisce anche `@rpath/`, che Homebrew
    usa per libwebp e compagnia: ignorarlo lascia moduli che non si caricano.
    """
    owner = os.path.dirname(referrer)
    if reference.startswith("@rpath/"):
        leaf = reference[len("@rpath/"):]
        remember_rpaths(referrer)
        for base in list(rpaths(referrer)) + RPATH_POOL:
            candidate = os.path.join(base, leaf)
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        return find_by_leaf(leaf)
    if reference.startswith("@loader_path/"):
        candidate = os.path.join(owner, reference[len("@loader_path/"):])
    elif reference.startswith("@executable_path/"):
        candidate = os.path.join(owner, reference[len("@executable_path/"):])
    else:
        candidate = reference
    return os.path.realpath(candidate) if os.path.exists(candidate) else None


def relocatable_deps(path):
    """
    Coppie (riferimento scritto nel binario, percorso reale) da portare nel
    bundle. Solleva un errore se un riferimento non si risolve: un modulo con
    una dipendenza mancante fallisce silenziosamente a runtime, e ImageMagick
    si limita a ignorare il formato.
    """
    result = []
    for reference in linked_libraries(path):
        if reference.startswith(SYSTEM_PREFIXES):
            continue
        real = resolve(reference, path)
        if real is None:
            raise SystemExit(
                f"Dipendenza non risolvibile: {reference}\n  richiesta da {path}"
            )
        if real.startswith(SYSTEM_PREFIXES):
            continue
        if os.path.samefile(real, path) if os.path.exists(real) else False:
            continue          # install name di sé stesso
        result.append((reference, real))
    return result


def dependency_closure(roots, known=None):
    """
    Restituisce (closure, plan, alias):
    - closure: real_path -> nome del file nel bundle, uno per libreria, così
      la stessa libreria non finisce dentro due volte con due nomi diversi;
    - plan: real_path -> [(riferimento scritto nel Mach-O, real_path)], calcolato
      sui file di origine. Le copie vanno riscritte in base a questo, non
      rianalizzate: nel bundle i nomi cambiano e @rpath non risolverebbe più.
    - alias: real_path -> nome nel bundle di una libreria che c'è già. I moduli
      innestati da una seconda installazione arrivano linkati alla *sua* copia
      di libMagickCore: ha lo stesso nome di file di quella già copiata, e
      portarla dentro significherebbe sovrascriverne una con l'altra. Si tiene
      quella dell'albero e ci si punta, che è poi ciò che rende l'innesto
      possibile — le due installazioni sono lo stesso identico build.

    `known` (nome file -> real_path) elenca ciò che è già nel bundle da una
    passata precedente: quelle librerie diventano alias invece di copie.
    """
    closure = {}
    plan = {}
    alias = {}
    seen = dict(known or {})
    queue = list(roots)
    while queue:
        current = os.path.realpath(queue.pop())
        if current in plan:
            continue
        deps = relocatable_deps(current)
        plan[current] = deps
        for _, real in deps:
            leaf = os.path.basename(real)
            if leaf in seen:
                if seen[leaf] != real:
                    alias[real] = leaf
                continue
            if real not in closure:
                closure[real] = leaf
                seen[leaf] = real
                queue.append(real)
    return closure, plan, alias


# --- riscrittura ---------------------------------------------------------

def rewrite(path, lib_relative, deps, closure, set_id=None):
    """
    Punta ogni dipendenza a @loader_path/<lib_relative>/<nome nel bundle>.
    Il nome nel bundle può differire da quello scritto nel Mach-O (per esempio
    libwebp.7.dylib → libwebp.7.2.0.dylib): usare sempre quello del bundle
    evita di ritrovarsi due copie della stessa libreria caricate insieme.
    `deps` arriva dall'analisi del file di origine.
    """
    os.chmod(path, 0o755)
    args = ["install_name_tool"]
    if set_id:
        args += ["-id", set_id]
    prefix = f"{lib_relative}/" if lib_relative else ""
    for reference, real in deps:
        leaf = closure.get(real, os.path.basename(real))
        args += ["-change", reference, f"@loader_path/{prefix}{leaf}"]
    if len(args) > 1:
        subprocess.run(args + [path], check=True, capture_output=True, text=True)


def verify(root):
    """
    Ogni riferimento deve essere di sistema o risolversi dentro il bundle.
    Un @rpath residuo o un @loader_path che punta nel vuoto è un errore:
    è esattamente il caso che fa sparire silenziosamente un formato.
    """
    problems = []
    checked = 0
    for dirpath, _, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            if not is_macho(path):
                continue
            checked += 1
            for reference in linked_libraries(path):
                if reference.startswith(SYSTEM_PREFIXES):
                    continue
                if reference.startswith("@loader_path/"):
                    target = os.path.normpath(
                        os.path.join(os.path.dirname(path), reference[len("@loader_path/"):])
                    )
                    if not os.path.exists(target):
                        problems.append((path, reference, "target inesistente"))
                    continue
                if os.path.basename(reference) == name:
                    continue      # install name di sé stesso
                problems.append((path, reference, "riferimento esterno al bundle"))
    return checked, problems


# --- delegate esterni ----------------------------------------------------

def prune_delegates(destination, search_path):
    """
    delegates.xml elenca programmi esterni (cwebp, gs, ffmpeg…) invocati per
    nome. Se il programma non c'è, ImageMagick non ripiega sul coder interno:
    la conversione va in errore. Le voci non soddisfacibili vanno rimosse.
    """
    removed = []
    for xml in glob.glob(os.path.join(destination, "etc", "ImageMagick-*", "delegates.xml")):
        with open(xml) as handle:
            text = handle.read()

        def keep(match):
            block = match.group(0)
            command = re.search(r'command="(.*?)"', block, re.S)
            if not command:
                return block
            decoded = (command.group(1)
                       .replace("&apos;", "'").replace("&quot;", '"')
                       .replace("&amp;", "&").replace("&gt;", ">").replace("&lt;", "<"))
            decoded = decoded.strip()
            if decoded.startswith(("'", '"')):
                program = decoded[1:].split(decoded[0], 1)[0]
            else:
                program = decoded.split(" ", 1)[0]
            program = os.path.basename(program)
            if program and shutil.which(program, path=search_path):
                return block
            removed.append(program or "?")
            return ""

        patched = re.sub(r"<delegate\b.*?/>", keep, text, flags=re.S)
        with open(xml, "w") as handle:
            handle.write(patched)

    if removed:
        unique = sorted(set(removed))
        log(f"delegate esterni rimossi ({len(removed)} voci): {', '.join(unique)}")
        log("i formati interessati usano ora i coder interni")
    return removed


# --- configurazione, manifest, firma -------------------------------------

def copy_config(prefix, destination):
    """
    I file XML stanno in tre posti: etc/ImageMagick-7 (policy, delegates),
    share/ImageMagick-7 (colori, tipi) e lib/ImageMagick*/config-* (configure.xml).
    """
    sources = []
    for pattern in ("etc/ImageMagick-*", "share/ImageMagick-*", "lib/ImageMagick*/config-*"):
        sources += glob.glob(os.path.join(prefix, pattern))

    copied = []
    for source in sources:
        if not os.path.isdir(source):
            continue
        relative = os.path.relpath(source, prefix)
        target = os.path.join(destination, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copytree(source, target, dirs_exist_ok=True, symlinks=False)
        copied.append(relative)
    if copied:
        log("configurazione copiata: " + ", ".join(copied))
    return copied


def write_manifest(destination, version, modules_relative, config_relatives, grafted=()):
    """
    Dice all'app dove sono le cose. I nomi contengono il quantum (Q16HDRI),
    che dipende da come è stata compilata questa installazione: meglio
    scriverlo qui che ricodificarlo nel codice Swift.
    """
    manifest = {
        "version": version,
        "executable": "bin/magick",
        "coderModulePath": f"{modules_relative}/coders" if modules_relative else None,
        "filterModulePath": f"{modules_relative}/filters" if modules_relative else None,
        "configurePaths": config_relatives,
        # Solo per tracciabilità: da qui si vede quali coder non vengono dalla
        # formula `imagemagick`. L'app ignora il campo.
        "graftedCoders": sorted(grafted),
    }
    with open(os.path.join(destination, "imagemagick-bundle.json"), "w") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")


def codesign_tree(root, identity=None):
    """
    Firma ogni Mach-O. Il codice annidato va firmato prima dell'app che lo
    contiene, altrimenti la firma del bundle non è valida.
    """
    if identity is None:
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    adhoc = identity == "-"

    targets = [
        os.path.join(dirpath, name)
        for dirpath, _, files in os.walk(root)
        for name in files
        if is_macho(os.path.join(dirpath, name))
    ]
    failures = 0
    for path in targets:
        args = ["codesign", "--force", "--sign", identity]
        if adhoc:
            # Con una firma ad-hoc l'hardened runtime attiva la library
            # validation, che confronta i Team ID: assenti da entrambe le
            # parti, dyld rifiuta di caricare le dylib. Con un Developer ID
            # i Team ID coincidono e si può attivare.
            args.append("--timestamp=none")
        else:
            args += ["--options", "runtime", "--timestamp"]
        result = subprocess.run(args + [path], capture_output=True, text=True)
        if result.returncode != 0:
            failures += 1
            log(f"attenzione: firma non riuscita per {os.path.basename(path)}: {result.stderr.strip()}")
    log(f"firmati {len(targets) - failures}/{len(targets)} file Mach-O con «{identity}»")


# --- alberi per architettura ---------------------------------------------

def binary_arches(path):
    """Architetture presenti in un Mach-O, secondo lipo."""
    out = subprocess.run(["lipo", "-archs", path], capture_output=True, text=True)
    return out.stdout.split()


def arch_trees(vendor):
    """
    Alberi presenti sotto <vendor>/<arch>/, uno per architettura. Un manifest
    direttamente in <vendor> significa albero singolo vecchio stile: si tratta
    come l'architettura della macchina, così un albero già versionato non
    smette di funzionare.
    """
    if os.path.exists(os.path.join(vendor, "imagemagick-bundle.json")):
        return {platform.machine(): vendor}
    trees = {}
    if os.path.isdir(vendor):
        for name in sorted(os.listdir(vendor)):
            path = os.path.join(vendor, name)
            if os.path.exists(os.path.join(path, "imagemagick-bundle.json")):
                trees[name] = path
    return trees


def wanted_arches():
    """
    Architetture che la build sta producendo. ARCHS è impostata da Xcode;
    fuori da Xcode vale quella della macchina.
    """
    return os.environ.get("ARCHS", "").split() or [platform.machine()]


def manifest_of(tree):
    with open(os.path.join(tree, "imagemagick-bundle.json")) as handle:
        return json.load(handle)


def merge_arch(destination, arch, tree):
    """
    Porta l'architettura `arch` dentro l'albero già copiato in `destination`:
    ogni Mach-O comune diventa fat, quelli presenti solo qui vengono aggiunti.

    I file esclusivi non sono un errore: se le due installazioni di partenza
    hanno versioni diverse di una dipendenza (libaom.3.14 contro libaom.3.15),
    ciascuna slice continua a riferirsi al file che conosce, e dyld carica solo
    quello dell'architettura in esecuzione. La verifica finale controlla che
    entrambi i riferimenti risolvano.
    """
    fused = added = 0
    for dirpath, _, files in os.walk(tree):
        for name in files:
            if name == STAMP:
                continue
            source = os.path.join(dirpath, name)
            relative = os.path.relpath(source, tree)
            target = os.path.join(destination, relative)

            if not os.path.exists(target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                shutil.copy2(source, target)
                added += 1
                continue

            if not (is_macho(source) and is_macho(target)):
                continue          # xml, .la, manifest: bastano quelli del primo albero
            if set(binary_arches(source)) <= set(binary_arches(target)):
                continue          # quest'architettura c'è già

            # lipo non può scrivere su un proprio input.
            fat = target + ".fat"
            subprocess.run(["lipo", "-create", target, source, "-output", fat],
                           check=True, capture_output=True, text=True)
            shutil.copystat(target, fat)
            os.replace(fat, target)
            fused += 1
    log(f"{arch}: {fused} Mach-O fusi, {added} file aggiunti")


# --- programma principale ------------------------------------------------

def cmd_vendor(vendor):
    """
    Costruisce l'albero rilocabile da un'installazione locale e lo scrive in
    <vendor>/<architettura>: le architetture restano alberi separati, ognuno
    generato sulla macchina che le corrisponde, e la fase di build sceglie o
    fonde in base a quelle che sta compilando.
    """
    prefix, magick = find_source_prefix()
    if not magick:
        raise SystemExit(
            "ImageMagick non trovato. Installalo (brew install imagemagick) "
            "oppure indica il prefisso con IMAGEMAGICK_PREFIX."
        )

    version = magick_version(magick)
    source_modules = find_modules_dir(prefix)

    # La cartella prende il nome dall'architettura del binario di partenza, non
    # da quella della macchina: sbagliare cartella qui produrrebbe un'app che
    # non parte, e nessun altro controllo se ne accorgerebbe.
    arches = binary_arches(magick)
    host = platform.machine()
    if not arches:
        raise SystemExit(f"Impossibile leggere l'architettura di {magick}.")
    arch = host if host in arches else arches[0]
    if len(arches) > 1:
        log(f"attenzione: {magick} è fat ({', '.join(arches)}), lo tratto come {arch}")
    if os.path.basename(vendor) != arch:
        vendor = os.path.join(vendor, arch)
    destination = vendor

    log(f"sorgente: {magick} (ImageMagick {version}, {arch})")

    shutil.rmtree(destination, ignore_errors=True)
    lib_dir = os.path.join(destination, "lib")
    bin_dir = os.path.join(destination, "bin")
    os.makedirs(lib_dir)
    os.makedirs(bin_dir)

    # 1. Moduli: caricati con dlopen a runtime, quindi invisibili a otool.
    #    Ricreo lo stesso percorso relativo dell'installazione di origine.
    modules_dir = None
    modules_relative = None
    module_sources = []
    module_copies = []
    extra_sources = []
    grafted_names = []
    if source_modules:
        modules_relative = os.path.relpath(source_modules, prefix)
        modules_dir = os.path.join(destination, modules_relative)
        shutil.copytree(source_modules, modules_dir)
        for dirpath, _, files in os.walk(source_modules):
            for name in files:
                if name.endswith(".so"):
                    source = os.path.join(dirpath, name)
                    module_sources.append(source)
                    module_copies.append(
                        (source, os.path.join(modules_dir, os.path.relpath(source, source_modules)))
                    )
        log(f"moduli copiati da {modules_relative}: {len(module_sources)}")

        # Coder innestati da una seconda installazione (imagemagick-full).
        extra_prefix = find_extra_prefix()
        if extra_prefix:
            grafted = graft_extra_coders(extra_prefix, version, os.path.join(modules_dir, "coders"))
            extra_sources = [source for source, _ in grafted]
            module_copies += grafted
            grafted_names = [
                os.path.basename(source).removesuffix(".so") for source, _ in grafted
            ]
            log(f"coder innestati da {extra_prefix}: {', '.join(grafted_names)}")
        else:
            log("attenzione: imagemagick-full non trovato, l'albero resterà senza "
                + ", ".join(EXTRA_CODERS).upper()
                + " (brew install imagemagick-full, oppure IMAGEMAGICK_EXTRA_PREFIX=…)")
        # I .la sono i descrittori libtool con cui ltdl trova i .so: servono.
        # Il campo libdir punta al prefisso originale e va azzerato, altrimenti
        # ltdl carica il .so dell'installazione di sistema invece del nostro.
        for la in glob.glob(os.path.join(modules_dir, "*", "*.la")):
            with open(la) as handle:
                text = handle.read()
            text = re.sub(r"^libdir=.*$", "libdir=''", text, flags=re.M)
            text = re.sub(r"^dependency_libs=.*$", "dependency_libs=''", text, flags=re.M)
            with open(la, "w") as handle:
                handle.write(text)
    else:
        log("build senza moduli caricabili: i coder sono compilati nel binario")

    # 2. Chiusura delle dipendenze: dal binario e da ogni modulo. I coder
    #    innestati vengono dopo, così le librerie in comune restano quelle
    #    dell'installazione di partenza e loro ci si agganciano.
    closure, plan, alias = dependency_closure([magick] + module_sources)
    if extra_sources:
        known = {leaf: real for real, leaf in closure.items()}
        extra_closure, extra_plan, extra_alias = dependency_closure(extra_sources, known=known)
        log(f"librerie in più per i coder innestati: {len(extra_closure)}")
        closure.update(extra_closure)
        plan.update(extra_plan)
        alias.update(extra_alias)
    names = {**closure, **alias}
    for real, leaf in closure.items():
        shutil.copy2(real, os.path.join(lib_dir, leaf))
    log(f"librerie copiate: {len(closure)}")

    # 3. Binario.
    bundled = os.path.join(bin_dir, "magick")
    shutil.copy2(magick, bundled)

    # 4. Riscrittura degli install name, secondo il piano calcolato sui sorgenti.
    rewrite(bundled, "../lib", plan[os.path.realpath(magick)], names)
    for real, leaf in closure.items():
        rewrite(os.path.join(lib_dir, leaf), "", plan.get(real, []), names,
                set_id=f"@loader_path/{leaf}")
    for source, copy in module_copies:
        depth = os.path.relpath(copy, lib_dir).count(os.sep)
        rewrite(copy, "/".join([".."] * depth), plan.get(os.path.realpath(source), []), names)

    # 5. Configurazione, delegate, manifest.
    config_relatives = copy_config(prefix, destination)
    prune_delegates(destination, search_path=f"{bin_dir}:/usr/bin:/bin")
    write_manifest(destination, version, modules_relative, config_relatives, grafted_names)

    # 6. Verifica.
    checked, problems = verify(destination)
    if problems:
        for path, reference, reason in problems[:10]:
            log(f"ERRORE {os.path.relpath(path, destination)} → {reference} ({reason})")
        raise SystemExit(f"{len(problems)} riferimenti non validi su {checked} Mach-O.")
    log(f"verifica: {checked} Mach-O, tutti i riferimenti risolvono nell'albero")

    # 7. Firma ad-hoc: su arm64 il codice non firmato non parte, ma l'identità
    #    dello sviluppatore non deve finire nei byte committati. La fase di
    #    build rifirma con l'identità della macchina.
    codesign_tree(destination, identity="-")

    total = sum(
        os.path.getsize(os.path.join(dirpath, name))
        for dirpath, _, files in os.walk(destination)
        for name in files
    )
    log(f"ImageMagick {version} pronto in {destination} ({total / 1e6:.1f} MB)")
    log("committa questa cartella: da qui in poi compilare non richiede Homebrew")
    log(f"per una build universale serve anche l'albero delle altre architetture, "
        f"generato allo stesso modo sulla macchina corrispondente")


def cmd_install(vendor, destination):
    """
    Copia nell'app l'albero delle architetture che la build sta producendo e
    lo rifirma. Con più architetture i Mach-O vengono fusi con lipo, così
    l'app ne contiene una copia sola, universale come il resto del binario.
    """
    available = arch_trees(vendor)
    if not available:
        log(f"nessun ImageMagick versionato in {vendor}: bundling saltato.")
        log("Ricostruiscilo con: Scripts/bundle-imagemagick.py vendor "
            f"{os.path.relpath(vendor) if vendor else 'Vendor/ImageMagick'}")
        log("Senza di esso l'app cercherà un ImageMagick installato sul sistema.")
        return

    wanted = wanted_arches()
    missing = [arch for arch in wanted if arch not in available]
    selected = [arch for arch in wanted if arch in available]
    if not selected:
        log(f"nessun albero per {', '.join(wanted)} (presenti: {', '.join(available)}): "
            "bundling saltato.")
        log(f"Generalo su una macchina {wanted[0]} con: "
            f"Scripts/bundle-imagemagick.py vendor {os.path.relpath(vendor)}")
        log("Senza di esso l'app cercherà un ImageMagick installato sul sistema.")
        return
    if missing:
        # Bundling parziale significa app che non parte sulle architetture
        # mancanti, e nessun errore fino al primo avvio là sopra.
        raise SystemExit(
            f"manca l'albero ImageMagick per {', '.join(missing)}, richiesto da ARCHS.\n"
            f"  presenti: {', '.join(available)}\n"
            f"  generalo su una macchina {missing[0]} con: "
            f"Scripts/bundle-imagemagick.py vendor {os.path.relpath(vendor)}"
        )

    manifests = {arch: manifest_of(available[arch]) for arch in selected}
    base = selected[0]
    layout = {arch: (m.get("coderModulePath"), m.get("filterModulePath"),
                     tuple(m.get("configurePaths") or []))
              for arch, m in manifests.items()}
    divergent = [arch for arch in selected if layout[arch] != layout[base]]
    if divergent:
        # I percorsi contengono il quantum (Q16HDRI): se non coincidono, i due
        # alberi vengono da build diverse di ImageMagick e il manifest, che è
        # uno solo, ne descriverebbe correttamente una sola.
        raise SystemExit(
            f"gli alberi {base} e {', '.join(divergent)} hanno layout diversi: "
            "rigenerali dalla stessa versione di ImageMagick."
        )
    versions = {arch: m.get("version", "?") for arch, m in manifests.items()}
    version = versions[base]
    if len(set(versions.values())) > 1:
        log("attenzione: versioni diverse tra le architetture (" +
            ", ".join(f"{a}: {v}" for a, v in versions.items()) +
            f"); il manifest dichiara {version}")

    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
    stamp_path = os.path.join(destination, STAMP)
    newest = max(os.path.getmtime(os.path.join(available[arch], "imagemagick-bundle.json"))
                 for arch in selected)
    stamp = f"{version}|{'+'.join(selected)}|{identity}|{newest}"
    if os.path.exists(stamp_path) and open(stamp_path).read().strip() == stamp:
        log(f"ImageMagick {version} ({'+'.join(selected)}) già installato e aggiornato: "
            "niente da fare.")
        return

    shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(available[base], destination, symlinks=False,
                    ignore=shutil.ignore_patterns(STAMP, ".git*"))
    log(f"ImageMagick {version} {base} copiato da "
        f"{os.path.relpath(available[base], os.getcwd())}")
    for arch in selected[1:]:
        merge_arch(destination, arch, available[arch])

    # Ricontrolla i riferimenti: intercetta un albero corrotto in transito,
    # per esempio da una conversione di fine riga fatta da git, e su un albero
    # fuso controlla anche le slice aggiunte, che portano con sé i propri.
    checked, problems = verify(destination)
    if problems:
        for path, reference, reason in problems[:10]:
            log(f"ERRORE {os.path.relpath(path, destination)} → {reference} ({reason})")
        raise SystemExit(f"albero versionato non valido: {len(problems)} riferimenti rotti.")
    log(f"verifica: {checked} Mach-O, tutti i riferimenti risolvono nel bundle")

    codesign_tree(destination)
    with open(stamp_path, "w") as handle:
        handle.write(stamp)


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "vendor":
        cmd_vendor(os.path.abspath(args[1]))
    elif len(args) == 3 and args[0] == "install":
        cmd_install(os.path.abspath(args[1]), os.path.abspath(args[2]))
    else:
        raise SystemExit(
            "Uso:\n"
            "  bundle-imagemagick.py vendor <cartella-vendor>   (scrive in <cartella-vendor>/<arch>)\n"
            "  bundle-imagemagick.py install <cartella-vendor> <destinazione>"
        )


if __name__ == "__main__":
    main()
