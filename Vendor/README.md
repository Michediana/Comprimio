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

    brew install imagemagick          # oppure IMAGEMAGICK_PREFIX=/percorso
    python3 Scripts/bundle-imagemagick.py vendor Vendor/ImageMagick
    git add Vendor/ImageMagick && git commit

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

### Versione minima di macOS

Gli alberi ereditano il `minos` delle bottle Homebrew da cui sono presi, che
non ha niente a che vedere con `MACOSX_DEPLOYMENT_TARGET`. Va controllato
prima di distribuire:

    otool -l Vendor/ImageMagick/*/bin/magick | grep -A2 LC_BUILD_VERSION

Un albero costruito da una bottle `arm64_tahoe` pretende macOS 26 anche se
l'app dichiara di supportare la 13.5, e l'app parte ma non converte niente.
Per un floor più basso servono bottle più vecchie (`arm64_sonoma`, `sonoma`)
o una compilazione da sorgente con `-mmacosx-version-min`.
