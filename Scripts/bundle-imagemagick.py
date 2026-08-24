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

Uso: bundle-imagemagick.py <cartella-di-destinazione>

Se ImageMagick non è installato esce con successo senza fare nulla: l'app
in quel caso ricade sul binario di sistema.
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys

STAMP = ".comprimio-bundle-stamp"

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
    """Nomi così come sono scritti nel Mach-O, install name incluso."""
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout
    return [line.strip().split(" (")[0] for line in out.splitlines()[1:] if line.strip()]


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


def dependency_closure(roots):
    """
    Restituisce (closure, plan):
    - closure: real_path -> nome del file nel bundle, uno per libreria, così
      la stessa libreria non finisce dentro due volte con due nomi diversi;
    - plan: real_path -> [(riferimento scritto nel Mach-O, real_path)], calcolato
      sui file di origine. Le copie vanno riscritte in base a questo, non
      rianalizzate: nel bundle i nomi cambiano e @rpath non risolverebbe più.
    """
    closure = {}
    plan = {}
    queue = list(roots)
    while queue:
        current = os.path.realpath(queue.pop())
        if current in plan:
            continue
        deps = relocatable_deps(current)
        plan[current] = deps
        for _, real in deps:
            if real not in closure:
                closure[real] = os.path.basename(real)
                queue.append(real)
    return closure, plan


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


def write_manifest(destination, version, modules_relative, config_relatives):
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
    }
    with open(os.path.join(destination, "imagemagick-bundle.json"), "w") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")


def codesign_tree(root):
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


# --- programma principale ------------------------------------------------

def main():
    if len(sys.argv) < 2:
        raise SystemExit("Uso: bundle-imagemagick.py <cartella-di-destinazione>")
    destination = os.path.abspath(sys.argv[1])

    prefix, magick = find_source_prefix()
    if not magick:
        log("ImageMagick non trovato sulla macchina di build: bundling saltato.")
        log("L'app userà il binario di sistema, se presente.")
        return

    version = magick_version(magick)
    source_modules = find_modules_dir(prefix)

    stamp_path = os.path.join(destination, STAMP)
    stamp = f"{magick}|{version}|{source_modules}|{os.path.getmtime(magick)}"
    if os.path.exists(stamp_path) and open(stamp_path).read().strip() == stamp:
        log(f"ImageMagick {version} già incluso e aggiornato: niente da fare.")
        return

    log(f"sorgente: {magick} (ImageMagick {version})")
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
    if source_modules:
        modules_relative = os.path.relpath(source_modules, prefix)
        modules_dir = os.path.join(destination, modules_relative)
        shutil.copytree(source_modules, modules_dir)
        for dirpath, _, files in os.walk(source_modules):
            for name in files:
                if name.endswith(".so"):
                    module_sources.append(os.path.join(dirpath, name))
        log(f"moduli copiati da {modules_relative}: {len(module_sources)}")
        # I .la sono i descrittori libtool con cui ltdl trova i .so: servono.
        # Il campo libdir punta al prefisso originale e va azzerato, altrimenti
        # ltdl carica il .so di Homebrew invece di quello del bundle.
        for la in glob.glob(os.path.join(modules_dir, "*", "*.la")):
            with open(la) as handle:
                text = handle.read()
            text = re.sub(r"^libdir=.*$", "libdir=''", text, flags=re.M)
            text = re.sub(r"^dependency_libs=.*$", "dependency_libs=''", text, flags=re.M)
            with open(la, "w") as handle:
                handle.write(text)
    else:
        log("build senza moduli caricabili: i coder sono compilati nel binario")

    # 2. Chiusura delle dipendenze: dal binario e da ogni modulo.
    closure, plan = dependency_closure([magick] + module_sources)
    for real, leaf in closure.items():
        shutil.copy2(real, os.path.join(lib_dir, leaf))
    log(f"librerie copiate: {len(closure)}")

    # 3. Binario.
    bundled = os.path.join(bin_dir, "magick")
    shutil.copy2(magick, bundled)

    # 4. Riscrittura degli install name, secondo il piano calcolato sui sorgenti.
    rewrite(bundled, "../lib", plan[os.path.realpath(magick)], closure)
    for real, leaf in closure.items():
        rewrite(os.path.join(lib_dir, leaf), "", plan.get(real, []), closure,
                set_id=f"@loader_path/{leaf}")
    for source in module_sources:
        copy = os.path.join(modules_dir, os.path.relpath(source, source_modules))
        depth = os.path.relpath(copy, lib_dir).count(os.sep)
        rewrite(copy, "/".join([".."] * depth), plan.get(os.path.realpath(source), []), closure)

    # 5. Configurazione, delegate, manifest.
    config_relatives = copy_config(prefix, destination)
    prune_delegates(destination, search_path=f"{bin_dir}:/usr/bin:/bin")
    write_manifest(destination, version, modules_relative, config_relatives)

    # 6. Verifica.
    checked, problems = verify(destination)
    if problems:
        for path, reference, reason in problems[:10]:
            log(f"ERRORE {os.path.relpath(path, destination)} → {reference} ({reason})")
        raise SystemExit(f"{len(problems)} riferimenti non validi su {checked} Mach-O.")
    log(f"verifica: {checked} Mach-O, tutti i riferimenti risolvono nel bundle")

    # 7. Firma.
    codesign_tree(destination)

    total = sum(
        os.path.getsize(os.path.join(dirpath, name))
        for dirpath, _, files in os.walk(destination)
        for name in files
    )
    log(f"ImageMagick {version} incluso ({total / 1e6:.1f} MB)")
    with open(stamp_path, "w") as handle:
        handle.write(stamp)


if __name__ == "__main__":
    main()
