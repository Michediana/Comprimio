//
//  AppStore.swift
//  Comprimio
//
//  Stato condiviso: lista file, impostazioni, elaborazione batch e anteprima.
//  ObservableObject (non @Observable) per restare compatibile con macOS 13.
//

import AppKit
import Combine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Risultato di una conversione di anteprima, trasferibile fra i task.
struct PreviewOutput: Sendable {
    let url: URL
    /// File da mostrare a schermo: coincide con `url` quando macOS sa
    /// decodificarlo, altrimenti è una copia PNG generata apposta.
    let displayURL: URL
    let byteSize: Int64
    let pixelSize: CGSize
}

@MainActor
final class AppStore: ObservableObject {

    /// Istanza condivisa: la finestra e l'app delegate lavorano sulla stessa lista.
    static let shared = AppStore()

    // MARK: - Stato

    @Published var items: [ImageItem] = []
    /// Il publisher di `@Published` emette in `willSet`: una sink su
    /// `$selection` leggerebbe ancora la selezione precedente e l'anteprima
    /// mostrerebbe il file sbagliato. `didSet` scatta a valore già aggiornato.
    @Published var selection: Set<ImageItem.ID> = [] {
        didSet {
            guard selection != oldValue else { return }
            refreshPreview()
        }
    }
    @Published var sortOrder: [KeyPathComparator<ImageItem>] = [
        KeyPathComparator(\ImageItem.name, order: .forward)
    ]
    @Published var settings: ConversionSettings = .load()

    @Published var install: MagickInstall?
    @Published var installError: String?

    @Published var isProcessing = false
    @Published var processedCount = 0
    @Published var lastRunSummary: String?
    /// Avanzamento delle conversioni in corso, una voce per corsia attiva.
    @Published private(set) var itemProgress: [ImageItem.ID: MagickProgress] = [:]

    // Anteprima
    @Published var previewOriginal: NSImage?
    @Published var previewResult: NSImage?
    @Published var previewResultSize: Int64?
    @Published var previewPixelSize: CGSize?
    @Published var isRenderingPreview = false
    @Published var previewError: String?
    /// Anteprima a piena risoluzione: serve solo quando l'utente ingrandisce.
    @Published private(set) var previewDetail = false

    private var previewTask: Task<Void, Never>?
    private var previewCancellation: MagickCancellation?
    private var batchCancellation: MagickCancellation?
    private var previewedItemID: ImageItem.ID?
    private var originalLoadedItemID: ImageItem.ID?
    private var processingTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private let previewDirectory: URL

    init() {
        previewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Comprimio-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)

        detectImageMagick()

        // Salva le impostazioni e rigenera l'anteprima quando qualcosa cambia.
        $settings
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] newSettings in
                newSettings.save()
                self?.refreshPreview()
            }
            .store(in: &cancellables)
    }

    // MARK: - ImageMagick

    func detectImageMagick() {
        guard let location = ImageMagick.locate() else {
            install = nil
            installError = String(localized: """
                The copy of ImageMagick bundled with Comprimio is missing or unusable. \
                Reinstalling the app should restore it.
                """)
            return
        }
        do {
            install = try ImageMagick.inspect(location)
            installError = nil
        } catch {
            install = nil
            installError = error.localizedDescription
        }
    }

    var isFormatSupported: Bool {
        guard let install else { return false }
        return install.supports(settings.outputFormat)
    }

    // MARK: - Gestione della lista

    func add(urls: [URL]) {
        for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            FolderAccess.shared.remember(url)
        }
        let expanded = expand(urls: urls)
        let existing = Set(items.map(\.id))
        let newItems = expanded
            .filter { !existing.contains($0) }
            .map { ImageItem(url: $0) }
        guard !newItems.isEmpty else { return }
        items.append(contentsOf: newItems)
        applySort()
        if selection.isEmpty, let first = items.first { selection = [first.id] }
        fillMissingPixelSizes()
    }

    /// Espande le cartelle in file immagine (ricorsivamente).
    private func expand(urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let child = enumerator?.nextObject() as? URL {
                    if ImageItem.isSupported(child) { result.append(child.standardizedFileURL) }
                }
            } else if ImageItem.isSupported(url) {
                result.append(url.standardizedFileURL)
            }
        }
        return result
    }

    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    func removeAll() {
        items = []
        selection = []
        lastRunSummary = nil
        clearPreview()
    }

    func applySort() {
        items.sort(using: sortOrder)
    }

    /// Il primo elemento selezionato nell'ordine della lista.
    /// `Set.first` non ha un ordine definito: con più file selezionati
    /// l'anteprima cambierebbe a caso.
    var selectedItem: ImageItem? {
        guard !selection.isEmpty else { return items.first }
        return items.first { selection.contains($0.id) }
    }

    var totalOriginalSize: Int64 { items.reduce(0) { $0 + $1.originalSize } }
    var totalOutputSize: Int64 { items.reduce(0) { $0 + ($1.outputSize ?? 0) } }

    // MARK: - Pannelli file

    func presentOpenPanel(directories: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.prompt = directories
            ? String(localized: "Add Folder")
            : String(localized: "Add Images")
        panel.message = directories
            ? String(localized: "Choose one or more folders of images.")
            : String(localized: "Choose the images to process.")
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            FolderAccess.shared.remember(url)
            settings.customFolderPath = url.path
            settings.destination = .customFolder
        }
    }

    func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Use")
        panel.message = String(localized: """
            Choose the logo to overlay. A PNG with a transparent background \
            gives the best result.
            """)
        if panel.runModal() == .OK, let url = panel.url {
            settings.watermark.imagePath = url.path
        }
    }

    // MARK: - Avanzamento per la barra

    /// L'immagine su cui puntare la barra di dettaglio: la prima ancora in
    /// lavorazione nell'ordine della lista, cioè quella partita da più tempo
    /// fra le corsie attive. Restare sulla più vecchia evita che la barra
    /// salti da un file all'altro a ogni aggiornamento.
    var focusedItem: (item: ImageItem, progress: MagickProgress)? {
        for item in items where item.status == .processing {
            if let progress = itemProgress[item.id] { return (item, progress) }
        }
        return nil
    }

    /// Quante conversioni girano in parallelo in questo momento.
    var activeCount: Int {
        items.reduce(0) { $0 + ($1.status == .processing ? 1 : 0) }
    }

    /// Avanzamento del batch: solo i file conclusi, così non torna indietro
    /// quando una corsia riparte da zero su una nuova fase.
    var batchProgress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(processedCount) / Double(items.count)
    }

    // MARK: - Elaborazione batch

    func startProcessing() {
        guard let install, !isProcessing, !items.isEmpty else { return }
        guard ensureDestinationAccess() else { return }

        isProcessing = true
        processedCount = 0
        lastRunSummary = nil
        itemProgress = [:]
        for index in items.indices {
            items[index].status = .pending
            items[index].outputSize = nil
            items[index].outputURL = nil
            items[index].errorMessage = nil
        }

        let settings = self.settings
        let location = install.location
        let cancellation = MagickCancellation()
        batchCancellation = cancellation
        let jobs = items.map { (id: $0.id, url: $0.url) }
        let lanes = max(1, min(ProcessInfo.processInfo.activeProcessorCount - 1, 8))

        processingTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                // Concorrenza limitata: `lanes` conversioni contemporanee,
                // una nuova ne parte ogni volta che una finisce.
                var next = 0

                func addTask(_ job: (id: ImageItem.ID, url: URL)) {
                    group.addTask {
                        await self?.setStatus(.processing, for: job.id)
                        let outcome = Self.process(
                            url: job.url,
                            settings: settings,
                            using: location,
                            cancellation: cancellation,
                            onProgress: { progress in
                                Task { @MainActor [weak self] in
                                    // Solo se l'elemento è ancora in lavorazione:
                                    // un aggiornamento in ritardo dopo Annulla
                                    // rimetterebbe una corsia fantasma nella UI.
                                    guard self?.isProcessing == true else { return }
                                    self?.itemProgress[job.id] = progress
                                }
                            }
                        )
                        await self?.finish(job.id, with: outcome)
                    }
                }

                while next < jobs.count && next < lanes {
                    addTask(jobs[next])
                    next += 1
                }
                while await group.next() != nil {
                    if Task.isCancelled { break }
                    guard next < jobs.count else { continue }
                    addTask(jobs[next])
                    next += 1
                }
            }
            self?.finishRun()
        }
    }

    /// Da chiamare alla chiusura dell'app: un sottoprocesso non muore con il
    /// padre, e resterebbe a lavorare dopo che la finestra è sparita.
    func cancelAllWork() {
        previewCancellation?.cancel()
        previewCancellation = nil
        cancelProcessing()
    }

    func cancelProcessing() {
        // Prima i sottoprocessi: annullare solo il Task li lascerebbe girare.
        batchCancellation?.cancel()
        batchCancellation = nil
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        itemProgress = [:]
    }

    /// Apre l'accesso alle cartelle in cui la conversione andrà a scrivere,
    /// chiedendolo all'utente se manca.
    ///
    /// Sotto sandbox scrivere accanto agli originali non è scontato: se i file
    /// sono stati scelti uno per uno, il permesso riguarda quei file e non la
    /// cartella. Chiederlo qui, una volta per cartella e prima di cominciare,
    /// evita che la conversione fallisca a metà lista.
    private func ensureDestinationAccess() -> Bool {
        var folders: [URL] = []
        for item in items {
            let folder = ImageMagick.outputURL(for: item.url, settings: settings)
                .deletingLastPathComponent().standardizedFileURL
            if !folders.contains(folder) { folders.append(folder) }
        }

        let access = FolderAccess.shared
        for folder in folders {
            if access.canWrite(to: folder) { continue }
            access.restore(folder)
            if access.canWrite(to: folder) { continue }
            guard access.requestAccess(to: folder) else {
                lastRunSummary = String(localized:
                    "Cannot write to “\(folder.lastPathComponent)”: permission denied.")
                return false
            }
        }
        return true
    }

    /// Lavoro pesante: gira fuori dal main actor.
    private nonisolated static func process(
        url: URL,
        settings: ConversionSettings,
        using location: MagickLocation,
        cancellation: MagickCancellation,
        onProgress: @escaping @Sendable (MagickProgress) -> Void
    ) -> Result<(URL, Int64), Error> {
        do {
            let target = ImageMagick.outputURL(for: url, settings: settings)
            let produced = try ImageMagick.convert(
                input: url,
                output: target,
                settings: settings,
                using: location,
                cancellation: cancellation,
                onProgress: onProgress
            )
            let attrs = try FileManager.default.attributesOfItem(atPath: produced.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            return .success((produced, size))
        } catch {
            return .failure(error)
        }
    }

    private func setStatus(_ status: ProcessingStatus, for id: ImageItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }

    private func finish(_ id: ImageItem.ID, with outcome: Result<(URL, Int64), Error>) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let (url, size)):
            items[index].status = .done
            items[index].outputURL = url
            items[index].outputSize = size
        case .failure(let error):
            items[index].status = .failed
            items[index].errorMessage = error.localizedDescription
        }
        itemProgress[id] = nil
        processedCount += 1
    }

    private func finishRun() {
        isProcessing = false
        processingTask = nil
        batchCancellation = nil
        itemProgress = [:]
        let done = items.filter { $0.status == .done }
        let failed = items.filter { $0.status == .failed }.count
        let before = done.reduce(Int64(0)) { $0 + $1.originalSize }
        let after = done.reduce(Int64(0)) { $0 + ($1.outputSize ?? 0) }
        var summary = String(localized: "\(done.count) files processed")
        summary += " · \(Fmt.bytes(before)) → \(Fmt.bytes(after))"
        if before > 0 {
            summary += " (\(Fmt.percent(1 - Double(after) / Double(before))))"
        }
        if failed > 0 { summary += " · " + String(localized: "\(failed) errors") }
        lastRunSummary = summary
    }

    func revealOutputInFinder() {
        let urls = items.compactMap(\.outputURL)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: - Anteprima

    func refreshPreview() {
        // Un'anteprima superata non serve più a nessuno: fermare anche il
        // processo evita di accumulare `magick` orfani a ogni modifica.
        previewCancellation?.cancel()
        previewTask?.cancel()
        guard let item = selectedItem, let install else {
            clearPreview()
            return
        }

        // Cambiando file, il risultato precedente non c'entra più nulla:
        // meglio la sola rotellina che un'immagine sbagliata attenuata.
        if previewedItemID != item.id {
            previewResult = nil
            previewResultSize = nil
            previewPixelSize = nil
            previewedItemID = item.id
            previewDetail = false
        }

        if originalLoadedItemID != item.id {
            loadOriginal(url: item.url, id: item.id, using: install.location)
        }
        previewError = nil
        isRenderingPreview = true

        let settings = self.settings
        let location = install.location
        let detail = previewDetail
        let cancellation = MagickCancellation()
        previewCancellation = cancellation
        let format = settings.targetFormat(for: item.url)
        let stem = "preview-\(abs(item.url.path.hashValue))"
        let destination = previewDirectory
            .appendingPathComponent(stem)
            .appendingPathExtension(format.fileExtension ?? "png")
        let proxyDestination = previewDirectory.appendingPathComponent("\(stem)-display.png")

        previewTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<PreviewOutput, Error> in
                do {
                    let produced = try ImageMagick.convert(
                        input: item.url,
                        output: destination,
                        settings: settings,
                        using: location,
                        preview: detail ? .full : .fast(fit: Self.previewFit),
                        cancellation: cancellation
                    )
                    let attrs = try FileManager.default.attributesOfItem(atPath: produced.path)
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    // ImageIO conosce una manciata di formati; il catalogo ne
                    // offre più di cento. Se non sa nemmeno misurarlo, il file
                    // va ricodificato in PNG per poterlo mostrare.
                    var display = produced
                    var pixels = Self.pixelSize(of: produced)
                    if pixels == nil,
                       let proxy = Self.displayProxy(
                           for: produced,
                           at: proxyDestination,
                           using: location,
                           cancellation: cancellation
                       ) {
                        display = proxy
                        pixels = Self.pixelSize(of: proxy)
                    }
                    return .success(PreviewOutput(
                        url: produced,
                        displayURL: display,
                        byteSize: size,
                        pixelSize: pixels ?? .zero
                    ))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.isRenderingPreview = false
                switch outcome {
                case .success(let output):
                    self.previewResult = NSImage(contentsOf: output.displayURL)
                    self.previewResultSize = output.byteSize
                    // PDF e simili: ImageIO non li misura ma AppKit li disegna,
                    // e a quel punto la dimensione la sa l'immagine caricata.
                    self.previewPixelSize = output.pixelSize == .zero
                        ? self.previewResult?.size
                        : output.pixelSize
                    self.previewError = self.previewResult == nil
                        ? "Anteprima non visualizzabile per questo formato (\(destination.pathExtension.uppercased()))."
                        : nil
                case .failure(let error):
                    self.previewResult = nil
                    self.previewResultSize = nil
                    self.previewPixelSize = nil
                    self.previewError = error.localizedDescription
                }
            }
        }
    }

    /// Chiamata quando l'utente ingrandisce l'anteprima: a quel punto la
    /// versione ridotta non basta più e il file va riconvertito per intero.
    /// Resta attiva finché non si cambia file.
    func enablePreviewDetail() {
        guard !previewDetail else { return }
        previewDetail = true
        refreshPreview()
    }

    /// Carica l'immagine di partenza mostrata a sinistra.
    ///
    /// Molti formati che ImageMagick legge — PCX, FITS, XCF, i raw delle
    /// fotocamere meno diffuse — sono ignoti a ImageIO, e il riquadro
    /// resterebbe vuoto: per quelli l'originale passa da una copia PNG.
    /// Si fa una volta per file, non a ogni ritocco delle impostazioni.
    private func loadOriginal(url: URL, id: ImageItem.ID, using location: MagickLocation) {
        originalLoadedItemID = id
        if let image = NSImage(contentsOf: url) {
            previewOriginal = image
            return
        }
        previewOriginal = nil
        let destination = previewDirectory
            .appendingPathComponent("original-\(abs(url.path.hashValue)).png")
        Task { [weak self] in
            let proxy = await Task.detached(priority: .userInitiated) {
                Self.displayProxy(for: url, at: destination, using: location, cancellation: nil)
            }.value
            guard let self, self.originalLoadedItemID == id, let proxy else { return }
            self.previewOriginal = NSImage(contentsOf: proxy)
        }
    }

    /// Copia PNG di un file che ImageIO non sa aprire. `nil` se nemmeno
    /// ImageMagick riesce a rileggerlo: i formati di sola scrittura (braille,
    /// PostScript di livello 2 e 3…) non sono visualizzabili in alcun modo.
    private nonisolated static func displayProxy(
        for source: URL,
        at destination: URL,
        using location: MagickLocation,
        cancellation: MagickCancellation?
    ) -> URL? {
        // `[0]`: dei formati multipagina (PDF, GIF, DCX) all'anteprima serve
        // solo la prima immagine.
        let result = try? ImageMagick.run(
            location,
            arguments: ["\(source.path)[0]", "PNG:\(destination.path)"],
            cancellation: cancellation
        )
        guard result?.exitCode == 0,
              FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return destination
    }

    /// Completa le dimensioni in pixel dei file che ImageIO non sa leggere
    /// chiedendole a `magick identify`. Solo per quelli: un processo per ogni
    /// file di una cartella trascinata sarebbe uno spreco.
    private func fillMissingPixelSizes() {
        guard let location = install?.location else { return }
        let pending = items.filter { $0.pixelSize == nil }.map(\.url)
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for url in pending {
                let size = await Task.detached(priority: .utility) { () -> CGSize? in
                    guard let output = try? ImageMagick.run(
                        location,
                        arguments: ["identify", "-ping", "-format", "%w %h", "\(url.path)[0]"]
                    ), output.exitCode == 0 else { return nil }
                    let numbers = output.standardOutput
                        .split(separator: " ")
                        .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    guard numbers.count == 2 else { return nil }
                    return CGSize(width: numbers[0], height: numbers[1])
                }.value
                guard let self, let size else { continue }
                guard let index = self.items.firstIndex(where: { $0.url == url }) else { continue }
                self.items[index].pixelSize = size
            }
        }
    }

    private func clearPreview() {
        previewCancellation?.cancel()
        previewCancellation = nil
        previewedItemID = nil
        originalLoadedItemID = nil
        previewDetail = false
        previewOriginal = nil
        previewResult = nil
        previewResultSize = nil
        previewPixelSize = nil
        previewError = nil
        isRenderingPreview = false
    }

    /// Lato massimo dell'anteprima veloce, in pixel.
    private static let previewFit = 1600

    /// L'anteprima è rimpicciolita: la dimensione mostrata è indicativa
    /// se il file reale sarà più grande dell'anteprima.
    var previewIsDownscaled: Bool {
        guard !previewDetail, let original = selectedItem?.pixelSize else { return false }
        return max(original.width, original.height) > CGFloat(Self.previewFit)
    }

    private nonisolated static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }
}
