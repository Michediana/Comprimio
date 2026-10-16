# Roadmap: Comprimio per iPad e iPhone

Stato: **fasi 1–5 completate nel simulatore**, manca la misura su iPhone reale · Branch di lavoro: `ios-port`

Obiettivo: portare Comprimio su iPadOS e iOS con le stesse opzioni di
conversione del Mac, **lasciando l'app Mac com'è**.

---

## Vincoli

- **L'app Mac non cambia comportamento.** Nel suo codice sono ammessi solo
  blocchi `#if os(macOS)` che non cambiano ciò che viene compilato per macOS.
  Il target Mac, la fase di build «Includi ImageMagick nel bundle»,
  `Vendor/ImageMagick`, gli entitlement e la CI di release restano dove sono.
- **Stessa logica delle opzioni.** `ImageMagick.arguments(…)` è unica e
  condivisa: le stesse impostazioni devono dare lo stesso file su Mac e su iOS.
- **Universal Purchase**: il target iOS usa lo stesso bundle ID
  `com.michediana.Comprimio`.

## Perché su iOS serve un motore diverso

Su iOS non esistono `Process` né `posix_spawn`: il binario `magick` non si
può lanciare. Inoltre l'App Store iOS accetta solo framework, non dylib
sciolte, e i moduli caricati con libltdl non sono un'opzione.

Su iOS ImageMagick gira quindi **dentro il processo**, compilato come
XCFramework statico con i coder inclusi (`--without-modules`) e la
configurazione inclusa (`--enable-zero-configuration`), e viene invocato con
`MagickImageCommand`, che accetta lo stesso `argv` del binario `magick`.
Non `MagickCommandGenesis`: il wrapper serve solo per `-bench`/`-duration` e
chiama `setlocale(LC_ALL, "")`, che in un'app cambierebbe il locale C di
tutto il processo. Le parti che cambiano:

| Mac (sottoprocesso) | iOS (nel processo) |
|---|---|
| Avanzamento da `-monitor` su stderr | Callback `SetImageInfoProgressMonitor` → `MagickProgress` |
| Annullamento con `Process.terminate()` | Il callback restituisce `MagickFalse` |
| Messaggi di errore da stderr | La CLI consuma le eccezioni con `CatchException`: `SetErrorHandler` le raccoglie, per thread |
| Crash di `magick` isolato | Gli errori fatali (allocazioni fallite) chiamano `exit()` anche con un gestore proprio: la difesa sono i limiti delle risorse |
| Configurazione con l'ambiente del processo | Inclusa nella libreria, nessun file XML e nessuna variabile |

## Struttura del progetto

```
Comprimio/                 app Mac, invariata (alcuni file anche nel target iOS)
ComprimioiOS/              app iOS/iPadOS: App, AppStore (stato, motore, budget), Views
Packages/MagickEngine/     LibraryEngine, ImageIOBridge + test nel simulatore (solo iOS)
Scripts/build-imagemagick-ios.sh   cross-compila ImageMagick e le dipendenze
Vendor/ImageMagick-iOS/    ImageMagick.xcframework (ios-arm64, ios-arm64-simulator),
                           Licenses/ con i testi e licenses.json
```

| File esistente | Nel target iOS |
|---|---|
| `Models/ConversionSettings`, `OutputFormat`, `ImageItem`, `Support/Formatting` | Condivisi senza modifiche |
| `Services/ImageMagick.swift` | Condiviso, con `#if os(macOS)` attorno a `Process`, `MagickLocation`, `runsOnThisMac` |
| `Models/WatermarkSettings` | Condiviso, con `#if` su `NSFontManager` (iOS: `UIFont.familyNames`) |
| `Services/AppStore`, `FolderAccess`, `Views/*`, `ComprimioApp` | Riscritti in `ComprimioiOS/` |
| `Views/PreviewZoom` | Condiviso: lo stato dello zoom; la NSView che cattura gli eventi è in `#if os(macOS)` |
| `Localizable.xcstrings`, `Assets.xcassets`, `ComprimioIcon.icon` | Condivisi |
| `InfoPlist.xcstrings`, entitlement, `Support/DebugSnapshot`, `Support/LiquidGlass` | Solo Mac |

Nel progetto la cartella `Comprimio/` è un gruppo sincronizzato di entrambi i
target; i file solo Mac sono elencati uno per uno nell'eccezione del target
iOS (Xcode non applica l'esclusione di una cartella intera). **Un file nuovo
in `Comprimio/Views/` va aggiunto a quell'elenco**, altrimenti entra anche
nella build iOS.

## Formati e licenze

Su iOS si **escludono** x265 (GPL-2), libde265 e libraw (LGPL), liblqr e glib
(LGPL, servono solo a `-liquid-rescale`, che Comprimio non usa). Per i
formati che ne dipendevano si usa ImageIO:

| Formato | Mac | iOS |
|---|---|---|
| HEIC (lettura/scrittura) | libheif + libde265 + x265 | ImageIO (encoder hardware) |
| RAW delle fotocamere (lettura) | libraw (`dng.so`) | ImageIO / `CIRAWFilter` |
| AVIF | libheif + libaom | libheif + libaom (BSD) |
| Tutti gli altri | coder ImageMagick | coder ImageMagick |

Il passaggio (`MagickEngine/ImageIOBridge.swift`) funziona così: ImageIO
decodifica in un TIFF non compresso e lo passa a ImageMagick. Il TIFF
riproduce ciò che ImageMagick leggerebbe sul Mac:

- **profondità dell'originale**: 8 bit se il file ne ha 8, 16 altrimenti,
  come libheif (un TIFF sempre a 16 bit farebbe uscire a 16 bit anche i PNG);
  i raw sempre a 16 bit in sRGB, come libraw configurato da ImageMagick;
- **orientamento applicato ai pixel** e tag riportato a 1, come libheif e
  libraw: senza, un HEIC ruotato uscirebbe storto quando `-auto-orient` è
  spento. Le rotazioni sono esatte (multipli di 90°, nessun ricampionamento);
- profilo colore, EXIF, GPS e IPTC dell'originale.

Per HEIC in uscita, ImageMagick produce il TIFF (con `-compress None`, che
altrimenti erediterebbe la compressione dell'originale) e ImageIO lo codifica
con `-quality` riportata a `kCGImageDestinationLossyCompressionQuality`.

Il TIFF di ImageMagick non porta il profilo EXIF, e ImageMagick, leggendo un
TIFF, trasforma l'EXIF in proprietà che poi non riscrive. Con «Mantieni i
metadati» servono quindi due ponti, entrambi un JPEG 1×1:

- **in uscita**, lo stesso comando scrive anche
  `( +clone -sample 1x1! -write JPEG:… +delete )`: i suoi metadati (EXIF,
  GPS, IPTC, XMP, orientamento già aggiornato) vanno nell'HEIC. L'encoder
  ignora l'orientamento dei metadati, che passa fra le proprietà: con
  `-auto-orient` spento l'HEIC resta 1200×800 con tag 6, come sul Mac;
- **in ingresso** (HEIC/raw), ImageIO scrive l'EXIF dell'originale in un
  JPEG 1×1 in grigio «device» (nessun ICC, che `-profile` applicherebbe
  convertendo i colori) e ImageMagick lo riceve con `-profile JPEG:…`. Il file
non è lo stesso del Mac (x265 contro l'encoder di sistema), ma ha dimensioni,
profilo e metadati uguali. L'utente vede gli stessi formati del Mac. Il menu
resta costruito da `writableFormats` più HEIC e HEIF (`ImageIOBridge.canEncodeHEIC`).

Senza codec HEVC ImageMagick elenca comunque HEIC e HEIF in sola lettura, e
il coder DNG elenca i raw delle fotocamere: entrambi fallirebbero (il primo
senza decoder, il secondo cercando un programma esterno). Il passaggio da
ImageIO va quindi deciso prima, con `ImageIOBridge.decodesInput(_:)`, non
chiedendo a ImageMagick.

## Memoria

Il Mac usa Q16HDRI, cioè pixel in virgola mobile. Misure della fase 1 su una
foto da 48 MP (8064×6048), `-auto-orient -resize 50% -quality 82` verso WebP,
simulatore su Apple silicon:

| Build | Picco | Tempo | WebP |
|---|---|---|---|
| Mac Q16HDRI (sottoprocesso) | 1.063 MB | 2,6–2,8 s | 844.040 byte |
| iOS Q16, nessun limite | 499 MB | 4,3 s | 844.062 byte |
| iOS Q16, limite 384 MB | 360 MB | 3,3 s | 844.062 byte |
| iOS Q16, limite 256 MB | 221 MB | 3,9 s | 844.062 byte |
| iOS Q8, nessun limite | 255 MB | 3,8 s | 858.558 byte |

(Tempi presi con la macchina sotto carico per l'indicizzazione di Spotlight:
valgono come ordine di grandezza.)

Decisioni:

- **Q16 senza HDRI**: stesso file del Mac a meno di arrotondamenti. La Q8
  dimezza la memoria ma perde i 16 bit e cambia i file;
- **limite delle risorse** con `LibraryEngine.setMemoryLimit`, calcolato da
  `os_proc_available_memory()` e diviso per le corsie: oltre il limite
  ImageMagick usa la cache su disco nella cartella temporanea, e nel
  simulatore non costa tempo apprezzabile. Da verificare su iPhone;
- corsie parallele calcolate sulla memoria, non sui core (indicativamente 1–2
  su iPhone, 2–3 su iPad), e **una sola** per AVIF/HEIC (vedi la nota sul
  parallelismo: quegli encoder hanno già un pool di thread proprio).

## Versioni minime

iOS/iPadOS **17**. `BGContinuedProcessingTask` e Liquid Glass solo con
`#available(iOS 26.0, *)`.

---

## Fasi

### Fase 1 — Prova di fattibilità del motore
La fase più rischiosa: se va bene, il resto è lavoro prevedibile.

- [x] `Scripts/build-imagemagick-ios.sh`: ImageMagick 7.1.2-30 + libjpeg-turbo,
      libpng, libwebp (zlib e bzip2 dell'SDK) per `ios-arm64` e
      `ios-arm64-simulator`, `--without-modules --disable-openmp`, output
      come XCFramework statico. I thread POSIX restano: senza, i semafori di
      ImageMagick sono vuoti e le corsie parallele non sarebbero sicure
- [x] Configurazione inclusa nella libreria (`--enable-zero-configuration`)
      invece dei file XML nel bundle
- [x] `Packages/MagickEngine`: `LibraryEngine.run(arguments:)` con
      `MagickImageCommand`. Il collegamento con `arguments(…)` del Mac
      arriva in fase 3
- [x] Avanzamento tramite callback, annullamento, gestori di errore,
      corsie parallele indipendenti (8 test nel simulatore)
- [x] Misure su una foto da 48 MP nel simulatore, Q8 e Q16 (vedi «Memoria»)
- [x] **Decisione:** Q16 senza HDRI, con limite delle risorse
- [ ] Misure su iPhone e iPad reali: aprire `Packages/MagickEngine/Package.swift`
      in Xcode, scegliere il dispositivo e lanciare i test (⌘U) con
      `MAGICK_FIXTURE` nello schema

**Fatto quando:** un JPEG da 48 MP si converte in WebP su iPhone senza
crash, con avanzamento e annullamento funzionanti.

### Fase 2 — Dipendenze complete
- [x] libtiff, lcms2, openjpeg, libjxl (+ highway, brotli), libaom + libheif
      (solo AVIF), freetype, OpenEXR (+ Imath, OpenJPH), libdeflate, zstd,
      xz, e libxml2 dell'SDK (come sul Mac: MSL, SVG interno, URL). Versioni
      lette dalle librerie dell'albero Mac, non dalle formule Homebrew di oggi
- [x] Verifica automatica nello script: `-list format` eseguito nel
      simulatore e confrontato con quello dell'albero Mac, modo compreso.
      Differenze ammesse in `expected_format_differences`, ognuna motivata:
      276 formati, 192 scrivibili
- [x] Passaggio ImageIO per HEIC (lettura e scrittura) e RAW (lettura), con
      test sugli otto orientamenti EXIF
- [x] Elenco delle licenze delle dipendenze, da mostrare nell'app
      (`Vendor/ImageMagick-iOS/Licenses/licenses.json`)
- [x] `Vendor/README.md`: sezione su come aggiornare l'albero iOS
- [ ] Decodifica raw provata su scatti veri (`MAGICK_RAW_FIXTURE`), e HEIC
      su un dispositivo: il simulatore può non avere l'encoder

**Fatto quando:** l'elenco dei formati iOS coincide con quello del Mac.

### Fase 3 — Codice condiviso e target iOS
- [x] Target `Comprimio iOS` nel progetto, stesso bundle ID, iOS 17,
      iPhone e iPad, senza «Designed for iPad» sul Mac; MagickEngine come
      pacchetto locale; schema condiviso. Simulatore solo arm64 (come
      l'XCFramework)
- [x] `#if os(macOS)` in `ImageMagick.swift` e `WatermarkSettings.swift`:
      solo righe aggiunte. Su iOS `MagickError`, `MagickProgress` e
      `MagickCancellation` arrivano da MagickEngine; la tabella delle fasi
      resta condivisa (`phaseLabel(forTag:)`)
- [x] Verifica della build Mac, Release, prima e dopo: stessa lista di
      sorgenti, stesso contenuto del bundle, stessi simboli, sezioni
      `__text`, `__cstring`, `__const` e metadati Swift identiche byte per
      byte in arm64 e x86_64 (cambiano solo UUID/firma e i nomi casuali
      delle rendition in `Assets.car`)
- [ ] Prova a mano dell'app Mac su un batch di riferimento
- [x] `AppStore` iOS sopra `LibraryEngine`, con `CGImage` al posto di
      `NSImage`; corsie e limite di memoria in `ConversionBudget` (valori di
      partenza, da tarare in fase 6). Uscita provvisoria in
      `Documenti/<sottocartella>`, visibile in File; schermata provvisoria
      per provare il motore
- [x] Collegare `ImageIOBridge`: HEIC/raw in ingresso (anche come logo della
      filigrana) decodificati dopo `arguments(…)`, che deve vedere
      l'estensione originale; HEIC/HEIF in uscita scritti come TIFF e poi
      codificati; EXIF conservato nei due sensi (vedi «Formati e licenze»);
      file intermedi in una cartella per conversione, cancellata anche con
      errore o annullamento. `identify` diventa `-ping … info:file`
- [x] Provato nel simulatore: JPEG→WebP/HEIC/PCX, HEIC→HEIC/PNG/WebP/JPEG,
      qualità, `-strip`, `-auto-orient` spento, logo HEIC, testo, anteprima
      via PNG, annullamento prima e durante, nessuna cartella rimasta; due
      test nuovi nel pacchetto (18 in tutto)

### Fase 4 — App iPad
- [x] `NavigationSplitView`: lista nella sidebar, impostazioni nell'inspector
      (cinque schede come sul Mac, a icone), anteprima nel dettaglio con la
      barra di avanzamento in fondo
- [x] Importazione: `.fileImporter` (file e cartelle), `PhotosPicker` con
      `preferredItemEncoding: .current` (l'originale, non un JPEG), drag &
      drop con `loadInPlaceFileRepresentation`. Ciò che non arriva «in
      loco» è copiato in `tmp/Comprimio-import`, una sottocartella per
      file, cancellata quando il file esce dalla lista
- [x] Anteprima affiancata (impilata in verticale) con `MagnifyGesture` +
      `DragGesture` e doppio tocco, sullo `PreviewZoom` del Mac. Ingrandendo,
      anche l'originale si ricarica a piena risoluzione (fino a 8192 px)
- [x] Controlli: `TickedSlider` (tacche e numeri sotto uno `Slider`,
      allineati alla corsa misurata su `UISlider`), `TextField` al posto di
      `NativeTextField`
- [x] Miniature con `QLThumbnailGenerator`, in cache
- [x] Uscita (`OutputDestination`, preferenza solo iOS): cartella dell'app
      in File, cartella scelta (bookmark), Foto (`PHAssetCreationRequest`
      con il file così com'è, permesso *add-only*), `ShareLink`. Il logo
      della filigrana è copiato in Application Support
- [x] Scorciatoie da tastiera come sul Mac (⌘O, ⇧⌘O, ⌥⌘O, ⌘↩, ⌘., ⌘R,
      ⌘+/⌘−/⌘0 sull'anteprima)
- [x] «Apri con» da File: `CFBundleDocumentTypes` per `public.image` in
      `ComprimioiOS/Info.plist` + `.onOpenURL`
- [x] Provato nel simulatore iPad (con agganci temporanei, non committati):
      lista e miniature, anteprima e zoom sincronizzato, conversione in HEIC
      nella cartella dell'app, JPEG nelle Foto, PCX rifiutato da Foto con
      errore per file. Build Mac ancora identica alla baseline
- [ ] Da provare a mano, perché il simulatore non si può toccare da qui:
      gesture con le dita, i tre importatori, la scelta della cartella,
      `ShareLink`, «Apri con», le scorciatoie, l'orizzontale (iPadOS ignora
      `requestGeometryUpdate` con il multitasking)

### Fase 5 — App iPhone
- [x] Flusso compatto con `NavigationStack` (`CompactContentView`), scelto
      da `ContentView` con la size class compatta o sull'iPhone (anche un
      Pro Max in orizzontale): lista con Converti in fondo → tocco su una
      riga → anteprima (riquadri impilati). Le impostazioni sono un foglio
      a mezza altezza che lascia toccare ciò che sta sotto, così
      l'anteprima si aggiorna mentre si cambiano
- [x] Sorgente predefinita: Libreria Foto. Il `+` apre le Foto con un tocco
      (File e cartella tenendo premuto); a lista vuota «Scegli foto» e
      «Sfoglia File». Senza una scelta salvata, sull'iPhone anche la
      destinazione è Foto (sull'iPad resta la cartella dell'app)
- [x] Salvataggio nelle Foto e condivisione come azioni principali: dopo il
      batch la barra mostra «Salva nelle Foto», Condividi e Riconverti;
      l'anteprima di un file convertito ha Salva e Condividi per quel file.
      «Salva nelle Foto» funziona anche con le altre destinazioni (riapre
      l'accesso alla cartella scelta); con la destinazione Foto indica che
      è già fatto. Ciò che Foto rifiuta (PCX…) non si ripropone
- [x] Provato nel simulatore iPhone 17 (con agganci temporanei, non
      committati): lista vuota, lista, avanzamento e Annulla, conversione
      nelle Foto, conversione nella cartella dell'app con «Salva nelle Foto»
      e «Mostra in File», anteprima, foglio delle impostazioni sopra
      l'anteprima. Corretta anche la miniatura che usciva dal quadrato con
      le immagini larghe (anche sull'iPad)
- [ ] Da provare a mano: PhotosPicker dal `+` e dalla lista vuota, il menu
      tenendo premuto, il foglio trascinato fra le due altezze, ShareLink,
      lo scorrimento per eliminare, l'iPad in Split View stretta (passa al
      flusso compatto)

### Fase 6 — Background e rifinitura
- [ ] `BGContinuedProcessingTask` per i batch (iOS 26), `beginBackgroundTask`
      prima di iOS 26
- [ ] Limiti di memoria e corsie tarati per dispositivo
- [ ] Gestione degli avvisi di memoria: sospendere le corsie, non crashare
- [ ] Localizzazione (`Localizable.xcstrings` condiviso dove possibile)
- [ ] Privacy: privacy manifest (`NSPhotoLibraryAddUsageDescription` c'è
      già dalla fase 4, solo in inglese)
- [ ] Tradurre le stringhe nuove di iOS (destinazioni, importazione,
      azioni dell'iPhone)
- [ ] Avvio lento nel simulatore appena acceso (~40 s prima del primo
      fotogramma): capire se è `ImageMagick.inspect()` sul main thread e
      se succede anche sul dispositivo

### Fase 7 — Release
- [ ] Job iOS separato in `.github/workflows/release.yml` (quello Mac non si tocca)
- [ ] Schermate e scheda App Store per iPhone e iPad
- [ ] TestFlight, poi pubblicazione con Universal Purchase

### In seguito (opzionale)
- Estensione azione «Comprimi con Comprimio» da Foto e File. Le estensioni
  hanno circa 120 MB di RAM: servirebbe un percorso solo ImageIO, senza
  ImageMagick.
- Valutare se adottare il passaggio ImageIO per HEIC anche sul Mac, per
  togliere x265 (GPL) dal bundle Mac.

---

## Decisioni aperte

| Decisione | Quando | Stato |
|---|---|---|
| Quantum Q8 o Q16 senza HDRI | fine fase 1 | **Q16 senza HDRI** |
| Limiti delle risorse e numero di corsie | fase 6 | 256 MB per corsia regge nel simulatore; da tarare su iPhone |
| Formato intermedio per il passaggio ImageIO | fase 2 | **TIFF non compresso alla profondità dell'originale** (8 o 16 bit) |
| libheif (LGPL-3.0) linkata staticamente per l'AVIF | prima della fase 7 | aperta: tenerla rispettando la LGPL (ricollegamento possibile), o togliere l'AVIF su iOS |
| Condividere i file o copiarli nel target iOS | fase 3 | **condividere** (gruppo sincronizzato con eccezioni per il target iOS) |
| Dove scrivere i file convertiti su iOS | fase 4 | **cartella dell'app, cartella scelta o Foto** (`OutputDestination`) |

## Rischi

| Rischio | Mitigazione |
|---|---|
| Una dipendenza non compila per iOS | Fase 1 solo con librerie note per funzionare; le altre una alla volta in fase 2 |
| Memoria insufficiente su foto grandi | Quantum ridotto, limiti delle risorse, cache su disco, meno corsie |
| Coder che chiama `exit()` o lascia stato globale sporco | Gestori di errore personalizzati (gli errori fatali escono comunque); test di robustezza su file corrotti |
| Misure falsate dallo scheduler | Le misure girano a QoS `.userInitiated`: con la QoS del test i tempi sono 20–25 volte più lunghi |
| Formati che spariscono senza errore (come la trappola 2 del Mac) | Verifica dei delegate e confronto di `-list format` con il Mac nello script di build |
| Formati elencati ma inutilizzabili (HEIC senza HEVC, raw senza libraw) | Il passaggio ImageIO si decide dall'estensione, non da ImageMagick |
| Le modifiche condivise cambiano il Mac | Solo blocchi `#if os(macOS)`; build Mac verificata alla fine della fase 3 |
