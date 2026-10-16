//
//  AppStore.swift
//  Comprimio iOS
//
//  Stato condiviso dell'app iOS: lista file, impostazioni, elaborazione batch
//  e anteprima. Segue l'AppStore del Mac; cambiano il motore (LibraryEngine
//  nel processo invece del binario `magick`), le immagini (`CGImage` invece
//  di `NSImage`), l'accesso ai file (URL security-scoped dei documenti scelti)
//  e la destinazione, che per ora è la cartella Documenti dell'app.
//

import Combine
import Foundation
import ImageIO
import MagickEngine
import SwiftUI

/// Risultato di una conversione di anteprima, trasferibile fra i task.
struct PreviewOutput: Sendable {
    let url: URL
    /// File da mostrare a schermo: coincide con `url` quando ImageIO sa
    /// decodificarlo, altrimenti è una copia PNG generata apposta.
    let displayURL: URL
    let byteSize: Int64
    let pixelSize: CGSize
}

@MainActor
final class AppStore: ObservableObject {

    static let shared = AppStore()

    // MARK: - Stato

    @Published var items: [ImageItem] = []
    /// `didSet` e non la sink su `$selection`: il publisher emette in
    /// `willSet` e l'anteprima mostrerebbe il file precedente.
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

    @Published private(set) var install: MagickInstall?

    @Published var isProcessing = false
    @Published var processedCount = 0
    @Published var lastRunSummary: String?
    /// Avanzamento delle conversioni in corso, una voce per corsia attiva.
    @Published private(set) var itemProgress: [ImageItem.ID: MagickProgress] = [:]

    // Anteprima
    @Published var previewOriginal: CGImage?
    @Published var previewResult: CGImage?
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
    /// File e cartelle scelti dall'utente con l'accesso aperto: fuori dal
    /// contenitore dell'app un URL si legge solo fra `start…` e `stop…`.
    private var accessedURLs: [URL] = []

    init() {
        previewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Comprimio-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)

        LibraryEngine.setMemoryLimit(ConversionBudget.current.memoryLimit)
        install = ImageMagick.inspect()

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

    var isFormatSupported: Bool {
        guard let install else { return false }
        return install.supports(settings.outputFormat)
    }

    // MARK: - Gestione della lista

    /// Aggiunge file e cartelle arrivati da `.fileImporter`, dal trascinamento
    /// o da «Apri con». L'accesso resta aperto finché il file è in lista:
    /// serve di nuovo per l'anteprima e per la conversione.
    func add(urls: [URL]) {
        for url in urls where url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
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
        releaseUnusedAccess()
    }

    func removeAll() {
        items = []
        selection = []
        lastRunSummary = nil
        clearPreview()
        releaseUnusedAccess()
    }

    /// Chiude l'accesso ai file e alle cartelle che non servono più a
    /// nessun elemento della lista.
    private func releaseUnusedAccess() {
        let paths = items.map(\.url.standardizedFileURL.path)
        accessedURLs.removeAll { url in
            let root = url.standardizedFileURL.path
            let inUse = paths.contains { $0 == root || $0.hasPrefix(root + "/") }
            if !inUse { url.stopAccessingSecurityScopedResource() }
            return !inUse
        }
    }

    func applySort() {
        items.sort(using: sortOrder)
    }

    /// Il primo elemento selezionato nell'ordine della lista.
    var selectedItem: ImageItem? {
        guard !selection.isEmpty else { return items.first }
        return items.first { selection.contains($0.id) }
    }

    var totalOriginalSize: Int64 { items.reduce(0) { $0 + $1.originalSize } }
    var totalOutputSize: Int64 { items.reduce(0) { $0 + ($1.outputSize ?? 0) } }

    // MARK: - Destinazione

    /// Dove finiscono i file convertiti: per ora `Documenti/<sottocartella>`
    /// dell'app, visibile in File. Scrivere accanto agli originali, in una
    /// cartella scelta o nelle Foto arriva con la fase 4.
    var outputFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = settings.subfolderName.isEmpty ? "Comprimio" : settings.subfolderName
        return documents.appendingPathComponent(name, isDirectory: true)
    }

    /// Il nome lo decide `ImageMagick.outputURL`, come sul Mac; cambia solo
    /// la cartella.
    private nonisolated static func outputURL(
        for input: URL,
        settings: ConversionSettings,
        folder: URL
    ) -> URL {
        var settings = settings
        settings.destination = .customFolder
        settings.customFolderPath = folder.path
        return ImageMagick.outputURL(for: input, settings: settings)
    }

    // MARK: - Avanzamento per la barra

    /// L'immagine su cui puntare la barra di dettaglio: la prima ancora in
    /// lavorazione nell'ordine della lista.
    var focusedItem: (item: ImageItem, progress: MagickProgress)? {
        for item in items where item.status == .processing {
            if let progress = itemProgress[item.id] { return (item, progress) }
        }
        return nil
    }

    var activeCount: Int {
        items.reduce(0) { $0 + ($1.status == .processing ? 1 : 0) }
    }

    /// Solo i file conclusi, così la barra non torna indietro.
    var batchProgress: Double {
        guard !items.isEmpty else { return 0 }
        return Double(processedCount) / Double(items.count)
    }

    // MARK: - Elaborazione batch

    func startProcessing() {
        guard install != nil, !isProcessing, !items.isEmpty else { return }

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
        let folder = outputFolder
        let cancellation = MagickCancellation()
        batchCancellation = cancellation
        let jobs = items.map { (id: $0.id, url: $0.url) }
        let lanes = ConversionBudget.current.lanes(for: settings.outputFormat)

        processingTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                // Concorrenza limitata: `lanes` conversioni contemporanee,
                // una nuova ne parte ogni volta che una finisce.
                var next = 0

                func addTask(_ job: (id: ImageItem.ID, url: URL)) {
                    group.addTask {
                        // Un `let`: il `self` debole è una variabile, e
                        // catturarla nel callback di avanzamento, che gira su
                        // un altro thread, non sarebbe sicuro.
                        guard let store = self else { return }
                        await store.setStatus(.processing, for: job.id)
                        // Le misure della fase 1: alla QoS ereditata dal task
                        // i tempi sono 20–25 volte più lunghi.
                        let outcome = await Task.detached(priority: .userInitiated) {
                            Self.process(
                                url: job.url,
                                settings: settings,
                                folder: folder,
                                cancellation: cancellation,
                                onProgress: { progress in
                                    Task { @MainActor in
                                        // Un aggiornamento in ritardo dopo Annulla
                                        // rimetterebbe una corsia fantasma nella UI.
                                        guard store.isProcessing else { return }
                                        store.itemProgress[job.id] = progress
                                    }
                                }
                            )
                        }.value
                        await store.finish(job.id, with: outcome)
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

    func cancelAllWork() {
        previewCancellation?.cancel()
        previewCancellation = nil
        cancelProcessing()
    }

    func cancelProcessing() {
        // Prima le conversioni: annullare solo il Task le lascerebbe girare.
        batchCancellation?.cancel()
        batchCancellation = nil
        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        itemProgress = [:]
    }

    /// Lavoro pesante: gira fuori dal main actor.
    private nonisolated static func process(
        url: URL,
        settings: ConversionSettings,
        folder: URL,
        cancellation: MagickCancellation,
        onProgress: @escaping @Sendable (MagickProgress) -> Void
    ) -> Result<(URL, Int64), Error> {
        do {
            let target = outputURL(for: url, settings: settings, folder: folder)
            let produced = try ImageMagick.convert(
                input: url,
                output: target,
                settings: settings,
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

    // MARK: - Anteprima

    func refreshPreview() {
        previewCancellation?.cancel()
        previewTask?.cancel()
        guard let item = selectedItem, install != nil else {
            clearPreview()
            return
        }

        // Cambiando file, il risultato precedente non c'entra più nulla.
        if previewedItemID != item.id {
            previewResult = nil
            previewResultSize = nil
            previewPixelSize = nil
            previewedItemID = item.id
            previewDetail = false
        }

        if originalLoadedItemID != item.id {
            loadOriginal(url: item.url, id: item.id)
        }
        previewError = nil
        isRenderingPreview = true

        let settings = self.settings
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
                       let proxy = ImageMagick.displayProxy(
                           for: produced,
                           at: proxyDestination,
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
            let image: CGImage?
            if case .success(let output) = outcome {
                image = await Task.detached(priority: .userInitiated) {
                    Self.loadImage(output.displayURL, maxPixels: detail ? nil : Self.previewFit)
                }.value
            } else {
                image = nil
            }
            guard !Task.isCancelled, let self else { return }
            self.isRenderingPreview = false
            switch outcome {
            case .success(let output):
                self.previewResult = image
                self.previewResultSize = output.byteSize
                self.previewPixelSize = output.pixelSize == .zero
                    ? image.map { CGSize(width: $0.width, height: $0.height) }
                    : output.pixelSize
                self.previewError = image == nil
                    ? String(localized: "Preview not available for this format (\(destination.pathExtension.uppercased())).")
                    : nil
            case .failure(let error):
                self.previewResult = nil
                self.previewResultSize = nil
                self.previewPixelSize = nil
                self.previewError = error.localizedDescription
            }
        }
    }

    /// Chiamata quando l'utente ingrandisce l'anteprima: la versione ridotta
    /// non basta più e il file va riconvertito per intero.
    func enablePreviewDetail() {
        guard !previewDetail else { return }
        previewDetail = true
        refreshPreview()
    }

    /// Carica l'immagine di partenza. I formati che ImageIO non conosce
    /// (PCX, FITS, XCF…) passano da una copia PNG fatta da ImageMagick,
    /// una volta per file.
    private func loadOriginal(url: URL, id: ImageItem.ID) {
        originalLoadedItemID = id
        previewOriginal = nil
        let destination = previewDirectory
            .appendingPathComponent("original-\(abs(url.path.hashValue)).png")
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                if let image = Self.loadImage(url, maxPixels: Self.originalFit) { return image }
                guard let proxy = ImageMagick.displayProxy(for: url, at: destination, cancellation: nil)
                else { return nil }
                return Self.loadImage(proxy, maxPixels: Self.originalFit)
            }.value
            guard let self, self.originalLoadedItemID == id else { return }
            self.previewOriginal = image
        }
    }

    /// Completa le dimensioni in pixel dei file che ImageIO non sa leggere.
    private func fillMissingPixelSizes() {
        let pending = items.filter { $0.pixelSize == nil }.map(\.url)
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for url in pending {
                let size = await Task.detached(priority: .utility) {
                    ImageMagick.pixelSize(of: url)
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
    private nonisolated static let previewFit = 1600
    /// Lato massimo dell'originale mostrato: un 48 MP decodificato per intero
    /// sono 192 MB solo per lo schermo.
    private nonisolated static let originalFit = 4096

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

    /// L'immagine con l'orientamento EXIF applicato, come la mostra
    /// `NSImage` sul Mac, ridotta a `maxPixels` di lato se serve.
    private nonisolated static func loadImage(_ url: URL, maxPixels: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let full = pixelSize(of: url).map { Int(max($0.width, $0.height)) } ?? 0
        let side = maxPixels.map { full > 0 ? min($0, full) : $0 } ?? full
        guard side > 0 else { return CGImageSourceCreateImageAtIndex(src, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
