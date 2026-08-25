//
//  ConversionSettings.swift
//  Comprimio
//
//  Tutte le impostazioni delle quattro schede, in un unico valore
//  serializzabile: così è facile persisterle e confrontarle per
//  invalidare l'anteprima.
//

import Foundation

struct ConversionSettings: Codable, Equatable {

    // MARK: - Conversione
    var outputFormat: OutputFormat = .keepOriginal
    var quality: Double = 82
    var lossless: Bool = false
    var keepMetadata: Bool = false
    var convertToSRGB: Bool = true
    var jpegProgressive: Bool = true
    var chromaSubsampling: ChromaSubsampling = .auto
    var pngCompressionLevel: Int = 9
    var pngPalette: Bool = false
    var webpMethod: Int = 4
    var jxlEffort: Int = 7
    var flattenAlpha: Bool = false
    var flattenColorHex: String = "#FFFFFF"

    // MARK: - Ridimensiona
    var resizeMode: ResizeMode = .none
    var percent: Double = 50
    var width: Int = 1920
    var height: Int = 1080
    var doNotEnlarge: Bool = true
    var resizeFilter: ResizeFilter = .lanczos
    var applyDPI: Bool = false
    var dpi: Int = 72

    // MARK: - Regolazioni
    var autoOrient: Bool = true
    var rotation: Rotation = .none
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var brightness: Double = 0      // -100…100
    var contrast: Double = 0        // -100…100
    var saturation: Double = 0      // -100…100
    var sharpen: Double = 0         // 0…5
    var blur: Double = 0            // 0…5
    var grayscale: Bool = false

    // MARK: - Filigrana
    var watermark = WatermarkSettings()

    // MARK: - Destinazione
    var destination: DestinationMode = .subfolder
    var customFolderPath: String = ""
    var subfolderName: String = "Comprimio"
    var namePrefix: String = ""
    var nameSuffix: String = ""
    var overwriteExisting: Bool = false

    var customFolderURL: URL? {
        customFolderPath.isEmpty ? nil : URL(fileURLWithPath: customFolderPath)
    }

    /// Formato di destinazione per un file di input.
    func targetFormat(for url: URL) -> OutputFormat {
        OutputFormat.resolved(outputFormat, forInputExtension: url.pathExtension)
    }

    // MARK: - Persistenza

    private static let key = "conversionSettings"

    static func load() -> ConversionSettings {
        guard let data = UserDefaults.standard.data(forKey: key) else { return ConversionSettings() }
        if let decoded = try? JSONDecoder().decode(ConversionSettings.self, from: data) {
            return decoded
        }
        // Il decoder sintetizzato di Swift *non* usa i valori di default per le
        // chiavi mancanti: fallisce. Senza questo recupero, aggiungere una sola
        // impostazione all'app azzererebbe tutte quelle già salvate dall'utente.
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = try? JSONSerialization.jsonObject(
                  with: JSONEncoder().encode(ConversionSettings())
              ) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: merging(defaults, with: saved)),
              let decoded = try? JSONDecoder().decode(ConversionSettings.self, from: merged)
        else { return ConversionSettings() }
        return decoded
    }

    /// I valori salvati hanno la precedenza; le chiavi che mancano arrivano dai
    /// default. Ricorsivo, così vale anche per i gruppi annidati (la filigrana).
    private static func merging(
        _ defaults: [String: Any],
        with saved: [String: Any]
    ) -> [String: Any] {
        var result = defaults
        for (key, value) in saved {
            if let nested = value as? [String: Any],
               let base = defaults[key] as? [String: Any] {
                result[key] = merging(base, with: nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
