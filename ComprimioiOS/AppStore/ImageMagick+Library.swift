//
//  ImageMagick+Library.swift
//  Comprimio iOS
//
//  La parte di `ImageMagick` che sul Mac lancia il binario `magick`. Qui gli
//  stessi argomenti di `ImageMagick.arguments(…)` passano a `LibraryEngine`,
//  che esegue ImageMagick dentro il processo, e HEIC e raw passano da ImageIO
//  (vedi docs/ROADMAP-iOS.md, «Formati e licenze»).
//

import Foundation
import MagickEngine

/// Il motore a disposizione: sul Mac c'è anche il percorso del binario,
/// qui la libreria è linkata nell'app.
struct MagickInstall: Sendable {
    let version: String
    let writableFormats: Set<String>

    func supports(_ format: OutputFormat) -> Bool {
        guard let name = format.magickName else { return true }
        return writableFormats.contains(name)
    }
}

extension MagickProgress {
    /// Fase in corso, già tradotta, come `MagickProgress.phase` sul Mac.
    var phase: String { ImageMagick.phaseLabel(forTag: tag) }
}

extension ImageMagick {

    // MARK: - Il motore

    /// Versione e formati scrivibili. HEIC e HEIF li scrive ImageIO:
    /// ImageMagick, senza codec HEVC, li elenca solo in lettura.
    static func inspect() -> MagickInstall {
        var writable = LibraryEngine.writableFormats
        if ImageIOBridge.canEncodeHEIC {
            writable.formUnion(["HEIC", "HEIF"])
        } else {
            writable.subtract(["HEIC", "HEIF"])
        }
        return MagickInstall(
            version: "ImageMagick \(LibraryEngine.version) Q\(LibraryEngine.quantumDepth)",
            writableFormats: writable
        )
    }

    // MARK: - Conversione

    /// Converte un file e restituisce l'URL prodotto. Stessi argomenti del
    /// Mac; cambiano solo gli estremi quando ImageMagick non sa leggere
    /// l'ingresso o scrivere l'uscita:
    ///
    /// - HEIC/HEIF e raw in ingresso (anche come logo della filigrana) sono
    ///   decodificati da ImageIO in un TIFF, che prende il posto del file;
    /// - HEIC/HEIF in uscita: ImageMagick scrive un TIFF non compresso, che
    ///   ImageIO codifica con la stessa qualità.
    ///
    /// I file intermedi stanno in una cartella temporanea propria, cancellata
    /// all'uscita in ogni caso: errore, annullamento o successo.
    static func convert(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        preview: PreviewQuality? = nil,
        cancellation: MagickCancellation? = nil,
        onProgress: (@Sendable (MagickProgress) -> Void)? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // L'anteprima riscrive sempre lo stesso file temporaneo.
        let destination = settings.overwriteExisting || preview != nil
            ? output
            : uniqueURL(output)

        let scratch = try ScratchFolder()
        defer { scratch.remove() }

        // `arguments` decide il formato dall'estensione dell'originale: va
        // chiamata con quello, e il TIFF sostituito dopo. Con «Mantieni
        // originale» un HEIC deve restare HEIC, non diventare TIFF.
        var args = arguments(settings: settings, input: input, output: destination, preview: preview)

        // Senza `-monitor` (che qui non serve) l'ingresso è il primo argomento.
        if ImageIOBridge.decodesInput(input), args.first == input.path {
            let tiff = scratch.file("input.tiff")
            try ImageIOBridge.decode(input, toTIFF: tiff)
            args[0] = tiff.path
            // ImageMagick legge l'EXIF del TIFF come proprietà, non come
            // profilo, e non lo riscriverebbe: lo si riattacca a parte.
            if settings.keepMetadata, let exif = exifProfile(of: input, in: scratch) {
                args.insert(contentsOf: ["-profile", "JPEG:" + exif.path], at: 1)
            }
        }
        try throwIfCancelled(cancellation)

        let watermark = settings.watermark
        if watermark.isEffective, watermark.mode == .image,
           ImageIOBridge.decodesInput(URL(fileURLWithPath: watermark.imagePath)),
           let index = args.dropFirst().firstIndex(of: watermark.imagePath) {
            let tiff = scratch.file("watermark.tiff")
            try ImageIOBridge.decode(URL(fileURLWithPath: watermark.imagePath), toTIFF: tiff)
            args[index] = tiff.path
        }
        try throwIfCancelled(cancellation)

        let format = settings.targetFormat(for: input)
        if format.family == .heic {
            // L'ultimo argomento è la destinazione («HEIC:/…»). Senza
            // `-compress None` il TIFF erediterebbe la compressione
            // dell'originale: da un JPEG, un TIFF compresso in JPEG.
            let tiff = scratch.file("output.tiff")
            args.removeLast()
            // Il TIFF perde il profilo EXIF, che sul Mac finisce nell'HEIC.
            // Una copia 1×1 in JPEG lo conserva insieme a GPS, IPTC e XMP, e
            // con l'orientamento già aggiornato da ImageMagick: la scrive lo
            // stesso comando, perché i metadati siano quelli dell'immagine
            // finale. Con `-strip` non c'è niente da conservare.
            var metadata: URL?
            if settings.keepMetadata {
                let sidecar = scratch.file("metadata.jpg")
                args += ["(", "+clone", "-sample", "1x1!", "-write", "JPEG:" + sidecar.path, "+delete", ")"]
                metadata = sidecar
            }
            args += ["-compress", "None", "TIFF:" + tiff.path]
            try LibraryEngine.run(arguments: args, cancellation: cancellation, onProgress: onProgress)
            try throwIfCancelled(cancellation)
            try ImageIOBridge.encodeHEIC(
                fromTIFF: tiff,
                to: destination,
                quality: quality(settings, format),
                metadataFrom: metadata
            )
        } else {
            try LibraryEngine.run(arguments: args, cancellation: cancellation, onProgress: onProgress)
        }

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw MagickError(message: String(localized: "ImageMagick could not complete the operation."))
        }
        return destination
    }

    /// La `-quality` che `arguments` darebbe al formato, da riportare
    /// sull'encoder di ImageIO; `nil` se non ne usa una.
    private static func quality(_ s: ConversionSettings, _ format: OutputFormat) -> Int? {
        guard format.supportsQuality, !(s.lossless && format.supportsLossless) else { return nil }
        return min(Int(s.quality), format.maxQuality)
    }

    /// Un JPEG 1×1 con l'EXIF di `source`, da passare a `-profile`:
    /// ImageMagick legge il file e attacca all'immagine i profili che trova,
    /// cioè il solo EXIF (in scala di grigi «device» ImageIO non incorpora un
    /// profilo colore, che farebbe convertire i colori). `nil` se
    /// l'originale non ha EXIF.
    private static func exifProfile(of source: URL, in scratch: ScratchFolder) -> URL? {
        let carrier = scratch.file("exif.jpg")
        return ImageIOBridge.writeEXIFCarrier(from: source, to: carrier) ? carrier : nil
    }

    private static func throwIfCancelled(_ cancellation: MagickCancellation?) throws {
        if cancellation?.cancelled == true {
            throw MagickError(message: String(localized: "Operation cancelled."))
        }
    }

    // MARK: - Utilità per l'anteprima e la lista

    /// Copia PNG della prima immagine di `source`, per i formati che ImageIO
    /// non sa mostrare. `nil` se nemmeno ImageMagick riesce a rileggerlo.
    static func displayProxy(for source: URL, at destination: URL, cancellation: MagickCancellation?) -> URL? {
        // `[0]`: dei formati multipagina (PDF, GIF, DCX) all'anteprima serve
        // solo la prima immagine.
        do {
            try LibraryEngine.run(
                arguments: ["\(source.path)[0]", "PNG:\(destination.path)"],
                cancellation: cancellation
            )
        } catch {
            return nil
        }
        return FileManager.default.fileExists(atPath: destination.path) ? destination : nil
    }

    /// Dimensioni in pixel lette da ImageMagick, per i file che ImageIO non
    /// sa aprire. Sul Mac è `magick identify`; nel processo lo stdout non si
    /// può leggere, e il testo va in un file.
    static func pixelSize(of source: URL) -> CGSize? {
        guard let scratch = try? ScratchFolder() else { return nil }
        defer { scratch.remove() }
        let report = scratch.file("size.txt")
        do {
            try LibraryEngine.run(arguments: [
                "-ping", "\(source.path)[0]", "-format", "%w %h", "info:\(report.path)"
            ])
        } catch {
            return nil
        }
        guard let text = try? String(contentsOf: report, encoding: .utf8) else { return nil }
        let numbers = text.split(separator: " ")
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard numbers.count == 2 else { return nil }
        return CGSize(width: numbers[0], height: numbers[1])
    }
}

/// Cartella per i file intermedi di una conversione, dentro la cartella
/// temporanea dell'app. Una per conversione, così le corsie parallele non
/// si pestano i piedi e cancellarla porta via tutto.
private struct ScratchFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Comprimio-work", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
