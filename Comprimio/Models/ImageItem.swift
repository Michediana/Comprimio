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

    /// Estensioni accettate nella lista.
    static let acceptedExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "webp", "avif", "heic", "heif",
        "tif", "tiff", "gif", "bmp", "psd", "svg", "ico", "jp2", "dng", "raw"
    ]

    static func isSupported(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }
}
