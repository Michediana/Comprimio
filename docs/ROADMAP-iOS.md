# Roadmap: Comprimio per iPad e iPhone

Stato: **da iniziare** · Branch di lavoro: `ios-port`

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
XCFramework statico con i coder inclusi (`--without-modules`), e viene
invocato con `MagickCommandGenesis`, che accetta lo stesso `argv` del
binario `magick`. Le parti che cambiano:

| Mac (sottoprocesso) | iOS (nel processo) |
|---|---|
| Avanzamento da `-monitor` su stderr | Callback `SetImageInfoProgressMonitor` → `MagickProgress` |
| Annullamento con `Process.terminate()` | Il callback restituisce `MagickFalse` |
| Crash di `magick` isolato | `SetFatalErrorHandler`/`SetErrorHandler` (il default chiama `exit()`) |
| Configurazione con l'ambiente del processo | `setenv("MAGICK_CONFIGURE_PATH", …)` prima di `MagickWandGenesis()` |

## Struttura del progetto

```
Comprimio/                 app Mac, invariata (alcuni file anche nel target iOS)
ComprimioiOS/              app iOS/iPadOS: App, AppStore, Views, LibraryEngine
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

Il Mac usa Q16HDRI, cioè 16 byte per pixel: una foto da 48 MP occupa circa
770 MB, e su iPhone jetsam chiude l'app. Su iOS:

- profondità **Q8** o **Q16 senza HDRI**, da decidere con le misure della fase 1;
- `SetMagickResourceLimit` (memoria, map, area) calcolato da
  `os_proc_available_memory()`, con la cache su disco nella cartella temporanea;
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

- [ ] `Scripts/build-imagemagick-ios.sh`: ImageMagick 7.1.2 + zlib,
      libjpeg-turbo, libpng, libwebp per `ios-arm64` e `ios-arm64-simulator`,
      `--without-modules --disable-openmp --without-threads`, output come
      XCFramework statico
- [ ] Configurazione minima nel bundle (`policy.xml`, `delegates.xml` vuoto,
      `colors.xml`, `type.xml`…)
- [ ] App iOS di prova con `LibraryEngine` che esegue `arguments(…)` con
      `MagickCommandGenesis`
- [ ] Avanzamento tramite callback, annullamento, gestori di errore
- [ ] Misure su una foto da 48 MP: picco di memoria e tempi in Q8 e in Q16
      senza HDRI, su iPhone e iPad reali
- [ ] **Decisione:** profondità del quantum e limiti delle risorse

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
| Quantum Q8 o Q16 senza HDRI | fine fase 1 | da misurare |
| Limiti delle risorse e numero di corsie | fine fase 1 | da misurare |
| Formato intermedio per il passaggio ImageIO | fase 2 | proposta: TIFF a 16 bit |
| Condividere i file o copiarli nel target iOS | fase 3 | proposta: condividere |

## Rischi

| Rischio | Mitigazione |
|---|---|
| Una dipendenza non compila per iOS | Fase 1 solo con librerie note per funzionare; le altre una alla volta in fase 2 |
| Memoria insufficiente su foto grandi | Quantum ridotto, limiti delle risorse, cache su disco, meno corsie |
| Coder che chiama `exit()` o lascia stato globale sporco | Gestori di errore personalizzati; test di robustezza su file corrotti |
| Formati che spariscono senza errore (come la trappola 2 del Mac) | Verifica automatica dei formati nello script di build |
| Le modifiche condivise cambiano il Mac | Solo blocchi `#if os(macOS)`; build Mac verificata alla fine della fase 3 |
