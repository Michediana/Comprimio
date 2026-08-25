//
//  ImageItem.swift
//  Comprimio
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ProcessingStatus: String, Hashable {
    case pending
    case processing
    case done
    case failed

    var label: String {
        switch self {
        case .pending: return "In attesa"
        case .processing: return "In corso…"
        case .done: return "Completato"
        case .failed: return "Errore"
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "circle.dashed"
        case .processing: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

struct ImageItem: Identifiable, Hashable {
    let id: URL          // il percorso identifica l'elemento: niente duplicati
    let url: URL
    var originalSize: Int64
    var pixelSize: CGSize?
    var formatName: String
    var status: ProcessingStatus = .pending
    var outputURL: URL?
    var outputSize: Int64?
    var errorMessage: String?

    init(url: URL) {
        self.id = url
        self.url = url
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.originalSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        self.formatName = url.pathExtension.uppercased()
        self.pixelSize = ImageItem.readPixelSize(url)
    }

    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }

    /// Rapporto di risparmio: positivo se il file è diminuito.
    var saving: Double? {
        guard let outputSize, originalSize > 0 else { return nil }
        return 1 - Double(outputSize) / Double(originalSize)
    }

    // Chiavi non opzionali per l'ordinamento della tabella.
    var sortOutputSize: Int64 { outputSize ?? -1 }
    var sortPixels: Double { (pixelSize?.width ?? 0) * (pixelSize?.height ?? 0) }
    var sortSaving: Double { saving ?? -.greatestFiniteMagnitude }

    private static func readPixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Estensioni che ImageMagick sa leggere ma non scrivere: i raw delle
    /// fotocamere, i formati di scambio di altri programmi, il medicale.
    /// Non hanno un formato di destinazione corrispondente, quindi non
    /// compaiono nel catalogo e vanno elencate qui.
    private static let readOnlyExtensions: Set<String> = [
        // Raw delle fotocamere (coder DNG, via libraw)
        "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "fff", "iiq",
        "k25", "kdc", "mdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "pef",
        "raf", "raw", "rmf", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
        // Formati di altri programmi e scanner
        "xcf", "cut", "mpo", "pwp", "rla", "rle", "sct", "sfw", "sti",
        "tim", "tm2", "pix", "jnx", "pes", "scr", "mac", "pcd", "pcds",
        "xps", "dcm", "dicom", "jbig", "jbg",
        // Vettoriali e animati: ImageMagick li rasterizza in ingresso, ma per
        // riscriverli servirebbero delegate che non abbiamo (potrace, ffmpeg).
        "svg", "svgz", "mvg", "msvg", "apng"
    ]

    /// Estensioni accettate nella lista: tutto ciò che ImageMagick sa leggere.
    /// Le sole estensioni dei formati scrivibili non basterebbero — un CR2 si
    /// apre e si converte benissimo, non si riscrive.
    static let acceptedExtensions: Set<String> = {
        var result = readOnlyExtensions
        // I campioni grezzi e i formati testuali restano fuori: un `.rgb` non
        // ha intestazione (ImageMagick non saprebbe che dimensioni ha) e
        // accettare `.txt` significherebbe raccogliere ogni nota trovata in
        // una cartella trascinata sulla finestra.
        let skipped: Set<FormatCategory> = [.rawSamples, .text]
        for format in OutputFormat.all where !skipped.contains(format.category) {
            if let ext = format.fileExtension { result.insert(ext) }
        }
        result.subtract(["map", "mono"])
        // Alias diffusi che non coincidono con il nome del coder.
        result.formUnion([
            "jpeg", "jpe", "tif", "pct", "epsf", "epsi", "six", "fts", "fit",
            "icb", "vda", "vst", "tpic", "j2c", "jpf", "jpx", "jpm", "heifs", "avifs"
        ])
        return result
    }()

    static func isSupported(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }
}
