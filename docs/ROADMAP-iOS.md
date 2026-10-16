# Roadmap: Comprimio per iPad e iPhone

Stato: **fase 1 completata nel simulatore**, manca la misura su iPhone reale · Branch di lavoro: `ios-port`

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
ComprimioiOS/              app iOS/iPadOS: App, AppStore, Views
Packages/MagickEngine/     LibraryEngine + test nel simulatore (solo iOS)
Scripts/build-imagemagick-ios.sh   cross-compila ImageMagick e le dipendenze
Vendor/ImageMagick-iOS/    ImageMagick.xcframework (ios-arm64, ios-arm64-simulator)
```

| File esistente | Nel target iOS |
|---|---|
| `Models/ConversionSettings`, `OutputFormat`, `ImageItem`, `Support/Formatting` | Condivisi senza modifiche |
| `Services/ImageMagick.swift` | Condiviso, con `#if os(macOS)` attorno a `Process`, `MagickLocation`, `runsOnThisMac` |
| `Models/WatermarkSettings` | Condiviso, con `#if` su `NSFontManager` (iOS: `UIFont.familyNames`) |
| `Services/AppStore`, `FolderAccess`, `Views/*`, `ComprimioApp` | Riscritti in `ComprimioiOS/` |

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

Il passaggio funziona così: ImageIO decodifica in un formato intermedio
senza perdita (TIFF a 16 bit) e lo passa a ImageMagick. Per HEIC in uscita,
ImageMagick produce il TIFF e ImageIO lo codifica. L'utente vede gli stessi
formati del Mac. Il menu resta costruito da `writableFormats` più i formati
ImageIO.

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
- [ ] libtiff, lcms2, openjpeg, libjxl (+ highway, brotli), libaom + libheif
      (solo AVIF), freetype, OpenEXR, libdeflate, libzstd, liblzma
- [ ] Verifica automatica nello script: ogni formato atteso compare in
      `-list format` come scrivibile
- [ ] Passaggio ImageIO per HEIC (lettura e scrittura) e RAW (lettura)
- [ ] Elenco delle licenze delle dipendenze, da mostrare nell'app
- [ ] `Vendor/README.md`: sezione su come aggiornare l'albero iOS

**Fatto quando:** l'elenco dei formati iOS coincide con quello del Mac.

### Fase 3 — Codice condiviso e target iOS
- [ ] Target `Comprimio iOS` nel progetto, stesso bundle ID
- [ ] `#if os(macOS)` in `ImageMagick.swift` e `WatermarkSettings.swift`
- [ ] Verifica: la build Mac è identica (stessi sorgenti compilati, app
      provata a mano su un batch di riferimento)
- [ ] `AppStore` iOS sopra `LibraryEngine`, con `CGImage` al posto di `NSImage`

### Fase 4 — App iPad
- [ ] `NavigationSplitView`: lista nella sidebar, impostazioni nell'inspector,
      anteprima nel dettaglio
- [ ] Importazione: `.fileImporter` (file e cartelle), `PhotosPicker`,
      drag & drop
- [ ] Anteprima affiancata con `MagnifyGesture` + `DragGesture` sincronizzati
- [ ] Controlli: `Slider` con tacche al posto di `TickSlider`, `TextField` al
      posto di `NativeTextField`
- [ ] Miniature con `QLThumbnailGenerator`
- [ ] Uscita: cartella scelta (bookmark security-scoped), Foto
      (`PHPhotoLibrary`, add-only), `ShareLink`
- [ ] Scorciatoie da tastiera (Converti, Annulla)
- [ ] «Apri con» da File: tipi di documento + `.onOpenURL`

### Fase 5 — App iPhone
- [ ] Flusso compatto con `NavigationStack`: lista → impostazioni (sheet) →
      anteprima
- [ ] Sorgente predefinita: Libreria Foto
- [ ] Salvataggio nelle Foto e condivisione come azioni principali

### Fase 6 — Background e rifinitura
- [ ] `BGContinuedProcessingTask` per i batch (iOS 26), `beginBackgroundTask`
      prima di iOS 26
- [ ] Limiti di memoria e corsie tarati per dispositivo
- [ ] Gestione degli avvisi di memoria: sospendere le corsie, non crashare
- [ ] Localizzazione (`Localizable.xcstrings` condiviso dove possibile)
- [ ] Privacy: `NSPhotoLibraryAddUsageDescription`, privacy manifest

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
| Formato intermedio per il passaggio ImageIO | fase 2 | proposta: TIFF a 16 bit |
| Condividere i file o copiarli nel target iOS | fase 3 | proposta: condividere |

## Rischi

| Rischio | Mitigazione |
|---|---|
| Una dipendenza non compila per iOS | Fase 1 solo con librerie note per funzionare; le altre una alla volta in fase 2 |
| Memoria insufficiente su foto grandi | Quantum ridotto, limiti delle risorse, cache su disco, meno corsie |
| Coder che chiama `exit()` o lascia stato globale sporco | Gestori di errore personalizzati (gli errori fatali escono comunque); test di robustezza su file corrotti |
| Misure falsate dallo scheduler | Le misure girano a QoS `.userInitiated`: con la QoS del test i tempi sono 20–25 volte più lunghi |
| Formati che spariscono senza errore (come la trappola 2 del Mac) | Verifica automatica dei formati nello script di build |
| Le modifiche condivise cambiano il Mac | Solo blocchi `#if os(macOS)`; build Mac verificata alla fine della fase 3 |
