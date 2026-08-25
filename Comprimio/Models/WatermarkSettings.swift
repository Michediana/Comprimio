//
//  WatermarkSettings.swift
//  Comprimio
//
//  Filigrana: un logo o un testo sovrapposto a tutte le immagini del batch.
//

import AppKit
import CoreText
import Foundation

enum WatermarkMode: String, Codable, CaseIterable, Identifiable {
    case none
    case image
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        // Chiave esplicita: in altre lingue «nessuna filigrana» e «nessuna
        // rotazione» non concordano allo stesso modo.
        case .none: return String(localized: "watermark.mode.none", defaultValue: "None")
        case .image: return String(localized: "Logo")
        case .text: return String(localized: "Text")
        }
    }
}

/// Le nove ancore di `-gravity`.
enum WatermarkPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    var id: String { rawValue }

    var gravity: String {
        switch self {
        case .topLeft: return "NorthWest"
        case .top: return "North"
        case .topRight: return "NorthEast"
        case .left: return "West"
        case .center: return "Center"
        case .right: return "East"
        case .bottomLeft: return "SouthWest"
        case .bottom: return "South"
        case .bottomRight: return "SouthEast"
        }
    }

    var label: String {
        switch self {
        case .topLeft: return String(localized: "Top left")
        case .top: return String(localized: "Top center")
        case .topRight: return String(localized: "Top right")
        case .left: return String(localized: "Left")
        case .center: return String(localized: "Center")
        case .right: return String(localized: "Right")
        case .bottomLeft: return String(localized: "Bottom left")
        case .bottom: return String(localized: "Bottom center")
        case .bottomRight: return String(localized: "Bottom right")
        }
    }

    /// Su quali assi vale il margine: solo dove la filigrana tocca un bordo.
    /// Al centro non ha senso, e su «in alto al centro» solo in verticale.
    var marginAxes: (x: Bool, y: Bool) {
        switch self {
        case .center: return (false, false)
        case .top, .bottom: return (false, true)
        case .left, .right: return (true, false)
        default: return (true, true)
        }
    }
}

struct WatermarkSettings: Codable, Equatable {
    var mode: WatermarkMode = .none

    // Logo
    var imagePath: String = ""
    /// Larghezza del logo in percentuale della larghezza dell'immagine.
    var imageScale: Double = 20

    // Testo
    var text: String = "© Comprimio"
    var fontFamily: String = "Helvetica"
    var colorHex: String = "#FFFFFF"
    var outline: Bool = true
    /// Corpo del carattere in percentuale della larghezza dell'immagine.
    var textScale: Double = 5

    // Comuni
    var opacity: Double = 45        // %
    var position: WatermarkPosition = .bottomRight
    var margin: Double = 3          // % della larghezza
    var rotation: Double = 0        // gradi
    var tile: Bool = false
    var tileGap: Double = 60        // % della dimensione della filigrana

    var imageURL: URL? {
        imagePath.isEmpty ? nil : URL(fileURLWithPath: imagePath)
    }

    /// Percentuale che governa la dimensione, diversa fra logo e testo.
    var scale: Double {
        mode == .text ? textScale : imageScale
    }

    /// `true` se c'è davvero qualcosa da sovrapporre. Un logo cancellato dal
    /// disco o un testo vuoto farebbero fallire ogni conversione del batch:
    /// meglio non aggiungere affatto gli argomenti.
    var isEffective: Bool {
        switch mode {
        case .none:
            return false
        case .image:
            guard let imageURL else { return false }
            return FileManager.default.isReadableFile(atPath: imageURL.path)
        case .text:
            return !text.trimmingCharacters(in: .whitespaces).isEmpty && fontFileURL != nil
        }
    }

    /// Motivo per cui la filigrana non verrà applicata, da mostrare nella UI.
    var problem: String? {
        switch mode {
        case .none:
            return nil
        case .image:
            if imagePath.isEmpty { return String(localized: "Choose the logo file.") }
            if !FileManager.default.isReadableFile(atPath: imagePath) {
                return String(localized: "The logo file is no longer readable: \(imagePath)")
            }
            return nil
        case .text:
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                return String(localized: "Type the text to overlay.")
            }
            if fontFileURL == nil {
                return String(localized: "The font “\(fontFamily)” is not available.")
            }
            return nil
        }
    }

    // MARK: - Caratteri

    /// File del carattere da passare a `magick`.
    ///
    /// Il binario è compilato senza fontconfig (`magick -list font` non elenca
    /// nulla e `-font Helvetica` fallisce con «unable to read font»), quindi il
    /// nome della famiglia non basta: serve il percorso del file, che qui
    /// arriva da CoreText.
    var fontFileURL: URL? {
        Self.fontFile(family: fontFamily)
    }

    static func fontFile(family: String) -> URL? {
        let descriptor = CTFontDescriptorCreateWithAttributes(
            [kCTFontFamilyNameAttribute: family] as CFDictionary
        )
        // `CTFontDescriptorCreateMatchingFontDescriptor` restituisce nil per una
        // famiglia inesistente, mentre creare direttamente il font ripiegherebbe
        // in silenzio su quello di sistema.
        guard let matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil),
              let url = CTFontDescriptorCopyAttribute(matched, kCTFontURLAttribute) as? URL,
              FileManager.default.isReadableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// Famiglie installate, calcolate una volta: interrogare NSFontManager a
    /// ogni redraw del menu costa parecchio.
    static let availableFontFamilies: [String] = NSFontManager.shared
        .availableFontFamilies
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

    // MARK: - Testo per `label:`

    /// Testo reso innocuo per `label:`.
    ///
    /// ImageMagick espande le sequenze percentuali anche nelle etichette (un
    /// `%[fx:w]` digitato dall'utente diventerebbe la larghezza dell'immagine) e
    /// interpreta una `@` iniziale come «leggi il testo da questo file», che
    /// stamperebbe il contenuto di un file qualsiasi su tutte le immagini.
    var escapedText: String {
        var escaped = text.replacingOccurrences(of: "%", with: "%%")
        if escaped.hasPrefix("@") { escaped = "\\" + escaped }
        return escaped
    }
}
