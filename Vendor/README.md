# Dipendenze versionate

## ImageMagick

`Vendor/ImageMagick/<architettura>/` contiene ImageMagick reso rilocabile: il
binario `magick`, la chiusura delle librerie da cui dipende e i moduli coder,
con gli install name riscritti in forma relativa a `@loader_path`. La fase di
build «Includi ImageMagick nel bundle» copia in
`Comprimio.app/Contents/Resources/ImageMagick` l'albero delle architetture
indicate da `ARCHS` e lo rifirma con l'identità della macchina che compila.

Le architetture sono alberi separati perché ImageMagick si installa come
binario nativo: da un Mac Intel non si produce l'albero arm64, né viceversa.
Ognuno va quindi generato sulla macchina corrispondente e committato. In fase
di build una sola architettura viene copiata così com'è; più di una vengono
fuse con `lipo`, e nell'app finisce un albero universale. Le due installazioni
di partenza non devono coincidere nei dettagli: se hanno versioni diverse di
una dipendenza (`libx265.216` contro `libx265.217`), il merge porta entrambi i
file e ogni slice continua a riferirsi al proprio.

**Compilare Comprimio non richiede quindi alcuna installazione di
ImageMagick.** I file qui sono firmati ad-hoc, così i byte versionati non
dipendono da chi ha costruito l'albero.

ImageMagick non esiste come pacchetto SwiftPM né come XCFramework: si
distribuisce come sorgente autotools, e il link statico su macOS non è
praticabile perché Apple non fornisce una libSystem statica. Includere
binario e dylib nel bundle è la strada indicata dai manutentori stessi
(vedi ImageMagick/ImageMagick discussione #7054).

### Aggiornare la versione

Serve un'installazione locale di ImageMagick da cui partire. Il comando
scrive nella sottocartella dell'architettura del binario di partenza, quindi
va ripetuto su un Mac di ogni architettura che si vuole supportare:

    brew install imagemagick imagemagick-full   # oppure IMAGEMAGICK_PREFIX=/percorso
    python3 Scripts/bundle-imagemagick.py vendor Vendor/ImageMagick
    git add Vendor/ImageMagick && git commit

Le due formule vanno tenute alla stessa versione: lo script si ferma se non
lo sono (vedi sotto).

Lo script verifica da sé che ogni riferimento Mach-O risolva dentro
l'albero e si ferma altrimenti: un modulo con una dipendenza mancante non
darebbe errore a runtime, ImageMagick si limiterebbe a non registrare il
formato. La versione incorporata è in
`Vendor/ImageMagick/<architettura>/imagemagick-bundle.json`.

Se manca l'albero di un'architettura richiesta da `ARCHS`, la build si ferma
con un errore: un bundling parziale darebbe un'app che non parte proprio là
dove l'albero manca, e non ci si accorgerebbe di nulla fino al primo avvio su
quella macchina. L'unica eccezione è quando non c'è nessun albero utilizzabile:
lì il bundling viene saltato e l'app cerca un ImageMagick installato sul
sistema, che è il modo di lavorare su un Mac di cui non si è ancora generato
l'albero.

### Coder innestati: JPEG XL, JPEG 2000, OpenEXR, raw

La formula `imagemagick` di Homebrew dipende da nove librerie e fra queste non
ci sono jpeg-xl, openjpeg, openexr né libraw: il suo albero non contiene
`jxl.so`, `jp2.so`, `exr.so`, e il suo `dng.so` non è linkato a libraw, così i
raw delle fotocamere finirebbero per passare da un `darktable-cli` che nel
bundle non c'è. `imagemagick-full` è la stessa identica versione compilata con
quelle dipendenze.

`bundle-imagemagick.py` prende da lì i soli moduli elencati in `EXTRA_CODERS`
e li innesta nell'albero, con le librerie che servono loro. Funziona perché le
due formule sono lo stesso build: i moduli innestati si agganciano al
`libMagickCore` già presente invece di portarsi dietro il proprio, e lo script
verifica che le versioni coincidano prima di toccare qualsiasi cosa.

Non si parte direttamente da `imagemagick-full` per due motivi. Il primo è il
peso: porterebbe librsvg con tutta la coda cairo/pango/X11, e l'albero
passerebbe da 42 a 55 MB. Il secondo è più serio: i suoi `pdf.so` e `ps.so`
sono linkati a `libgs`, cioè Ghostscript, che è AGPL — distribuire un'app che
lo include significa assumersene gli obblighi. Innestando i singoli moduli,
PDF, PostScript ed EPS restano quelli della formula normale, che li scrivono
senza Ghostscript.

Se `imagemagick-full` non è installato, lo script lo dice e prosegue: l'albero
che ne esce è valido, semplicemente senza quei formati. L'app non li mostra
nemmeno nel menu, perché interroga `magick -list format` all'avvio. Un'altra
installazione si indica con `IMAGEMAGICK_EXTRA_PREFIX`.

### Versione minima di macOS

Gli alberi ereditano il `minos` delle bottle Homebrew da cui sono presi, che
non ha niente a che vedere con `MACOSX_DEPLOYMENT_TARGET`. Va controllato
prima di distribuire:

    otool -l Vendor/ImageMagick/*/bin/magick | grep -A2 LC_BUILD_VERSION

Un albero costruito da una bottle `arm64_tahoe` pretende macOS 26 anche se
l'app dichiara di supportare la 13.5, e l'app parte ma non converte niente.
Per un floor più basso servono bottle più vecchie (`arm64_sonoma`, `sonoma`)
o una compilazione da sorgente con `-mmacosx-version-min`.
