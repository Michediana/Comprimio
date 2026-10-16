# Dipendenze versionate

## ImageMagick

`Vendor/ImageMagick/<architettura>/` contiene ImageMagick reso rilocabile: il
binario `magick`, la chiusura delle librerie da cui dipende e i moduli coder,
con gli install name riscritti in forma relativa a `@loader_path`. La fase di
build «Includi ImageMagick nel bundle» copia in
`Comprimio.app/Contents/Resources/ImageMagick` l'albero delle architetture
indicate da `ARCHS` e lo rifirma con l'identità della macchina che compila.
Il solo `bin/magick` riceve gli entitlement di `Scripts/magick.entitlements`:
sul Mac App Store ogni eseguibile del bundle deve dichiarare la sandbox, e
`magick` la eredita da Comprimio invece di averne una propria.

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
lì il bundling viene saltato e la build passa lo stesso, così su un Mac di cui
non si è ancora generato l'albero si può comunque lavorare sull'interfaccia.
L'app che ne esce si avvia ma non converte niente: dalla sandbox un
ImageMagick installato sulla macchina non è raggiungibile, e caricarne le
dylib violerebbe comunque la library validation, quindi quella nel bundle è
l'unica copia che Comprimio sa usare.

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

## ImageMagick per iOS

`Vendor/ImageMagick-iOS/ImageMagick.xcframework` è ImageMagick per iPhone e
iPad, usato dal pacchetto `Packages/MagickEngine`. L'app Mac non lo usa e
non ne dipende.

Su iOS non si può lanciare `magick` come sottoprocesso, e l'App Store non
accetta dylib sciolte. L'albero del Mac quindi non serve: qui ImageMagick
è una libreria statica, linkata nell'app e invocata dentro il processo con
`MagickImageCommand`, che accetta lo stesso `argv` del binario. Rispetto
all'albero Mac:

- **niente moduli**: i coder sono compilati dentro la libreria
  (`--without-modules`), quindi niente libltdl e niente descrittori `.la`;
- **configurazione inclusa** (`--enable-zero-configuration`): nessun file
  XML e nessuna variabile d'ambiente, e nessun delegate esterno;
- **Q16 senza HDRI**: su una foto da 48 MP il picco scende da 1,06 GB (Mac,
  Q16HDRI) a 500 MB, e il WebP prodotto differisce da quello del Mac di
  22 byte su 844 KB. La Q8 dimezzerebbe ancora la memoria, ma perde i 16 bit
  e cambia i file (+1,7%); il limite delle risorse fa meglio senza questi
  difetti (221 MB con 256 MB di limite, stesso tempo);
- **niente x265, libde265, libraw, liblqr, glib**: HEIC/HEIF e i raw delle
  fotocamere passano da ImageIO (`MagickEngine/ImageIOBridge.swift`), che
  li decodifica in un TIFF senza perdita prima di ImageMagick e codifica
  l'HEIC dal TIFF che ImageMagick produce. `-liquid-rescale` non c'è, e
  Comprimio non lo usa;
- **niente fontconfig**: non esiste su iOS. FreeType c'è, i font vanno
  indicati per percorso.

### Dipendenze

Le stesse dell'albero Mac, alle stesse versioni, lette dalle librerie in
`Vendor/ImageMagick/arm64` e non dalle formule Homebrew di oggi, che nel
frattempo sono andate avanti:

| Libreria | Versione | Serve a |
|---|---|---|
| ImageMagick | 7.1.2-30 | |
| libjpeg-turbo | 3.2.0 | JPEG, JNG, compressione JPEG nei TIFF |
| libpng | 1.6.59 (Mac: 1.6.58) | PNG e varianti, MNG, PNG nei font |
| libwebp | 1.6.0 | WebP, compressione WebP nei TIFF |
| libtiff | 4.7.2 | TIFF, BigTIFF, TIFF piramidale, fax G3/G4 |
| lcms2 | 2.19 | gestione colore (`-profile`, `-intent`) |
| FreeType | 2.14.3 | testo (filigrane, `label:`, `caption:`) |
| OpenJPEG | 2.5.4 | JPEG 2000 |
| libjxl + highway + brotli | 0.12.0, 1.4.0, 1.2.0 | JPEG XL |
| libheif + libaom | 1.23.1, 3.14.1 | AVIF (solo AV1, niente HEVC) |
| OpenEXR + Imath + OpenJPH + libdeflate | 3.4.15, 3.2.3, 0.31.0, 1.26 | OpenEXR |
| zstd, xz | 1.5.7, 5.8.3 | compressione Zstandard e LZMA (TIFF, MIFF) |

zlib, bzip2, iconv e libxml2 sono quelle dell'SDK iOS. Le licenze,
con il testo completo di ciascuna, sono in
`Vendor/ImageMagick-iOS/Licenses/` con un indice `licenses.json` da
mostrare nell'app.

**libheif è LGPL-3.0.** È l'unica dipendenza con licenza copyleft: linkata
staticamente nell'app, la LGPL chiede che chi la riceve possa ricollegare
l'app con una propria versione della libreria (per esempio fornendo, su
richiesta, i file oggetto dell'app). Le alternative, se non la si vuole:
togliere l'AVIF su iOS, o scriverlo con ImageIO quando lo saprà fare. Vedi
le decisioni aperte in `docs/ROADMAP-iOS.md`.

### Aggiornare l'albero iOS

    brew install cmake ninja pkg-config
    Scripts/build-imagemagick-ios.sh
    git add Vendor/ImageMagick-iOS && git commit

Lo script scarica i sorgenti, ne verifica lo SHA-256, compila gli slice
`ios-arm64` e `ios-arm64-simulator` e sostituisce l'XCFramework. Ci vuole
qualche minuto per slice: libaom, libjxl e OpenEXR sono le parti lunghe.
`QUANTUM=8` e `HDRI=yes` producono le varianti, `OUT=` le scrive altrove per
confrontarle.

Per cambiare una versione: aggiornare la riga in `SOURCES` (versione, URL,
SHA-256 dell'archivio, licenza) e rilanciare. Le versioni vanno tenute
uguali a quelle dell'albero Mac, per cui dopo aggiornato `Vendor/ImageMagick`
conviene leggere quelle nuove dalle librerie stesse, per esempio:

    otool -L Vendor/ImageMagick/arm64/lib/libheif.*.dylib

o, dove il numero nel nome non basta (lcms2, FreeType, OpenEXR), con la
funzione di versione della libreria (`cmsGetEncodedCMMversion`,
`FT_Library_Version`, `exr_get_library_version`) chiamata da Python con
`ctypes`.

Lo script si ferma in due casi, entrambi pensati per i formati che
spariscono in silenzio, come la trappola del Mac:

1. **delegate**: l'insieme trovato da configure deve essere esattamente
   quello atteso. Un delegate mancante non dà errori, e il formato non c'è;
2. **formati**: prima di sostituire l'XCFramework, compila un piccolo
   programma con lo slice del simulatore, lo esegue nel simulatore
   (`simctl spawn`) e confronta il suo `-list format` con quello
   dell'albero Mac, modo di lettura e scrittura compreso. Le differenze
   ammesse sono in `expected_format_differences`, ciascuna con il motivo;
   qualsiasi altra ferma la build. Il simulatore usato è il primo iPhone
   disponibile, o quello in `SIMULATOR=<UDID>`.

Se la verifica fallisce l'XCFramework versionato resta quello di prima.
`SKIP_FORMAT_CHECK=1` la salta, ma solo per prove locali: non va
committato un albero che non l'ha passata.

### Verificare

    cd Packages/MagickEngine
    xcodebuild test -scheme MagickEngine \
        -destination 'platform=iOS Simulator,name=iPhone 18 Pro'

Per misurare memoria e tempi su una foto vera si passa il file con
`TEST_RUNNER_MAGICK_FIXTURE=/percorso/foto.jpg`, e un limite di memoria con
`TEST_RUNNER_MAGICK_MEMORY_LIMIT_MB=256`. La misura gira con QoS
`.userInitiated`, come le corsie dell'app: con la QoS predefinita del test
i tempi risultano 20–25 volte più lunghi, perché lo scheduler lascia il
processo sui core a efficienza. Uno scatto raw per provare la decodifica
con ImageIO si passa con `TEST_RUNNER_MAGICK_RAW_FIXTURE`.
