//
//  OutputFormat.swift
//  Comprimio
//

import Foundation

enum OutputFormat: String, CaseIterable, Identifiable, Codable {
    case keepOriginal
    case jpeg
    case png
    case webp
    case avif
    case heic
    case tiff
    case gif
    case bmp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keepOriginal: return "Mantieni originale"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        }
    }

    /// Nome del formato per ImageMagick (`magick -list format`).
    var magickName: String? {
        switch self {
        case .keepOriginal: return nil
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .webp: return "WEBP"
        case .avif: return "AVIF"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .bmp: return "BMP"
        }
    }

    var fileExtension: String? {
        switch self {
        case .keepOriginal: return nil
        case .jpeg: return "jpg"
        case .png: return "png"
        case .webp: return "webp"
        case .avif: return "avif"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .gif: return "gif"
        case .bmp: return "bmp"
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .png, .bmp, .gif: return false
        default: return true
        }
    }

    var supportsLossless: Bool {
        self == .webp || self == .avif
    }

    var supportsAlpha: Bool {
        switch self {
        case .jpeg, .bmp: return false
        default: return true
        }
    }

    /// Formato effettivo per un file di input, risolvendo `.keepOriginal`.
    static func resolved(_ format: OutputFormat, forInputExtension ext: String) -> OutputFormat {
        guard format == .keepOriginal else { return format }
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "png": return .png
        case "webp": return .webp
        case "avif": return .avif
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        case "gif": return .gif
        case "bmp": return .bmp
        default: return .jpeg
        }
    }
}

enum ChromaSubsampling: String, CaseIterable, Identifiable, Codable {
    case auto, s444, s422, s420

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatico"
        case .s444: return "4:4:4 (nessuno)"
        case .s422: return "4:2:2"
        case .s420: return "4:2:0"
        }
    }

    var magickValue: String? {
        switch self {
        case .auto: return nil
        case .s444: return "4:4:4"
        case .s422: return "4:2:2"
        case .s420: return "4:2:0"
        }
    }
}

enum ResizeMode: String, CaseIterable, Identifiable, Codable {
    case none, percent, fit, width, height, exact, fill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nessun ridimensionamento"
        case .percent: return "Percentuale"
        case .fit: return "Rientra in (larghezza × altezza)"
        case .width: return "Larghezza fissa"
        case .height: return "Altezza fissa"
        case .exact: return "Dimensione esatta (deforma)"
        case .fill: return "Riempi e ritaglia"
        }
    }
}

enum ResizeFilter: String, CaseIterable, Identifiable, Codable {
    case lanczos, mitchell, catrom, triangle, point

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanczos: return "Lanczos (nitido)"
        case .mitchell: return "Mitchell"
        case .catrom: return "Catrom"
        case .triangle: return "Triangle (morbido)"
        case .point: return "Point (nearest)"
        }
    }

    var magickValue: String {
        switch self {
        case .lanczos: return "Lanczos"
        case .mitchell: return "Mitchell"
        case .catrom: return "Catrom"
        case .triangle: return "Triangle"
        case .point: return "Point"
        }
    }
}

enum Rotation: String, CaseIterable, Identifiable, Codable {
    case none, cw90, ccw90, deg180

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nessuna"
        case .cw90: return "90° orario"
        case .ccw90: return "90° antiorario"
        case .deg180: return "180°"
        }
    }

    var degrees: Int? {
        switch self {
        case .none: return nil
        case .cw90: return 90
        case .ccw90: return -90
        case .deg180: return 180
        }
    }
}

enum DestinationMode: String, CaseIterable, Identifiable, Codable {
    case subfolder, sameFolder, customFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subfolder: return "Sottocartella accanto all'originale"
        case .sameFolder: return "Stessa cartella dell'originale"
        case .customFolder: return "Cartella personalizzata"
        }
    }
}
