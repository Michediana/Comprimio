//
//  SettingsPane.swift
//  Comprimio
//
//  Colonna destra a schede: Conversione, Ridimensiona, Regolazioni, Destinazione.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case conversion, resize, adjust, destination

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conversion: return "Conversione"
        case .resize: return "Ridimensiona"
        case .adjust: return "Regolazioni"
        case .destination: return "Destinazione"
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab: SettingsTab = .conversion

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(SettingsTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Form {
                switch tab {
                case .conversion: ConversionTab()
                case .resize: ResizeTab()
                case .adjust: AdjustTab()
                case .destination: DestinationTab()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentPanel()
        }
        .padding(12)
    }
}

// MARK: - Conversione

private struct ConversionTab: View {
    @EnvironmentObject private var store: AppStore

    private var format: OutputFormat {
        if store.settings.outputFormat == .keepOriginal,
           let item = store.selectedItem {
            return store.settings.targetFormat(for: item.url)
        }
        return store.settings.outputFormat
    }

    var body: some View {
        SettingsGroup("Formato di destinazione") {
            Picker("Formato", selection: $store.settings.outputFormat) {
                ForEach(OutputFormat.allCases) { option in
                    Text(label(for: option)).tag(option)
                }
            }

            if store.settings.outputFormat == .keepOriginal {
                HelpText("Ogni immagine mantiene il suo formato; cambiano solo qualità e opzioni scelte qui sotto.")
            } else if let install = store.install, !install.supports(store.settings.outputFormat) {
                WarningText("Questa installazione di ImageMagick non può scrivere \(store.settings.outputFormat.label).")
            }
        }

        SettingsGroup("Compressione") {
            if format.supportsLossless {
                Toggle("Senza perdita di qualità", isOn: $store.settings.lossless)
            }

            if format.supportsQuality {
                ValueSlider(
                    title: "Qualità",
                    value: $store.settings.quality,
                    range: 1...100,
                    step: 1,
                    suffix: ""
                )
                .disabled(store.settings.lossless && format.supportsLossless)
                HelpText(qualityHint)
            } else {
                HelpText("\(format.label) è un formato senza perdita: la qualità non si applica.")
            }

            Toggle("Mantieni metadati (EXIF, IPTC, XMP)", isOn: $store.settings.keepMetadata)
            Toggle("Converti in sRGB", isOn: $store.settings.convertToSRGB)
        }

        if format == .jpeg {
            SettingsGroup("Opzioni JPEG") {
                Toggle("JPEG progressivo", isOn: $store.settings.jpegProgressive)
                Picker("Sottocampionamento croma", selection: $store.settings.chromaSubsampling) {
                    ForEach(ChromaSubsampling.allCases) { Text($0.label).tag($0) }
                }
                HelpText("4:2:0 riduce il peso; 4:4:4 conserva i dettagli di colore (testo, grafica).")
            }
        }

        if format == .png {
            SettingsGroup("Opzioni PNG") {
                ValueSlider(
                    title: "Livello di compressione",
                    value: Binding(
                        get: { Double(store.settings.pngCompressionLevel) },
                        set: { store.settings.pngCompressionLevel = Int($0) }
                    ),
                    range: 0...9,
                    step: 1,
                    suffix: ""
                )
                Toggle("Palette a 8 bit (PNG8)", isOn: $store.settings.pngPalette)
                HelpText("PNG8 riduce molto il peso su immagini con pochi colori.")
            }
        }

        if format == .webp {
            SettingsGroup("Opzioni WebP") {
                ValueSlider(
                    title: "Metodo (lento = più compresso)",
                    value: Binding(
                        get: { Double(store.settings.webpMethod) },
                        set: { store.settings.webpMethod = Int($0) }
                    ),
                    range: 0...6,
                    step: 1,
                    suffix: ""
                )
            }
        }

        SettingsGroup("Trasparenza") {
            Toggle("Appiattisci su colore di sfondo", isOn: $store.settings.flattenAlpha)
                .disabled(!format.supportsAlpha)
            HexColorField(hex: $store.settings.flattenColorHex)
                .disabled(!store.settings.flattenAlpha && format.supportsAlpha)
            if !format.supportsAlpha {
                HelpText("\(format.label) non supporta la trasparenza: viene appiattita automaticamente.")
            }
        }
    }

    private func label(for option: OutputFormat) -> String {
        guard let install = store.install, !install.supports(option) else { return option.label }
        return "\(option.label) (non disponibile)"
    }

    private var qualityHint: String {
        let q = Int(store.settings.quality)
        switch q {
        case 90...100: return "Qualità massima, risparmio ridotto."
        case 75..<90: return "Compromesso consigliato per il web."
        case 50..<75: return "Peso ridotto, artefatti visibili sui dettagli."
        default: return "Compressione aggressiva: forte perdita di qualità."
        }
    }
}

// MARK: - Ridimensiona

private struct ResizeTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsGroup("Ridimensionamento") {
            Picker("Modalità", selection: $store.settings.resizeMode) {
                ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
            }

            switch store.settings.resizeMode {
            case .none:
                HelpText("Le dimensioni in pixel restano invariate.")
            case .percent:
                ValueSlider(title: "Scala", value: $store.settings.percent, range: 1...400, step: 1, suffix: "%")
            case .fit, .exact, .fill:
                IntField(title: "Larghezza", value: $store.settings.width, suffix: "px")
                IntField(title: "Altezza", value: $store.settings.height, suffix: "px")
            case .width:
                IntField(title: "Larghezza", value: $store.settings.width, suffix: "px")
            case .height:
                IntField(title: "Altezza", value: $store.settings.height, suffix: "px")
            }

            if store.settings.resizeMode != .none {
                if store.settings.resizeMode != .exact && store.settings.resizeMode != .fill {
                    Toggle("Non ingrandire le immagini più piccole", isOn: $store.settings.doNotEnlarge)
                }
                Picker("Filtro di ricampionamento", selection: $store.settings.resizeFilter) {
                    ForEach(ResizeFilter.allCases) { Text($0.label).tag($0) }
                }
                HelpText(hint)
            }
        }

        SettingsGroup("Risoluzione di stampa") {
            Toggle("Imposta DPI", isOn: $store.settings.applyDPI)
            IntField(title: "DPI", value: $store.settings.dpi, suffix: "ppi")
                .disabled(!store.settings.applyDPI)
            HelpText("Modifica solo i metadati di densità, non il numero di pixel.")
        }
    }

    private var hint: String {
        switch store.settings.resizeMode {
        case .fit: return "L'immagine rientra nel rettangolo mantenendo le proporzioni."
        case .fill: return "L'immagine copre il rettangolo e viene ritagliata al centro."
        case .exact: return "Le proporzioni non vengono rispettate: l'immagine può deformarsi."
        default: return "Le proporzioni originali vengono mantenute."
        }
    }
}

// MARK: - Regolazioni

private struct AdjustTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsGroup("Orientamento") {
            Toggle("Applica l'orientamento EXIF", isOn: $store.settings.autoOrient)
            Picker("Rotazione", selection: $store.settings.rotation) {
                ForEach(Rotation.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Rifletti orizzontalmente", isOn: $store.settings.flipHorizontal)
            Toggle("Rifletti verticalmente", isOn: $store.settings.flipVertical)
        }

        SettingsGroup("Colore") {
            ValueSlider(title: "Luminosità", value: $store.settings.brightness, range: -100...100, step: 1, suffix: "")
            ValueSlider(title: "Contrasto", value: $store.settings.contrast, range: -100...100, step: 1, suffix: "")
            ValueSlider(title: "Saturazione", value: $store.settings.saturation, range: -100...100, step: 1, suffix: "")
                .disabled(store.settings.grayscale)
            Toggle("Scala di grigi", isOn: $store.settings.grayscale)
        }

        SettingsGroup("Dettaglio") {
            ValueSlider(title: "Nitidezza", value: $store.settings.sharpen, range: 0...5, step: 0.1, suffix: "", decimals: 1)
            ValueSlider(title: "Sfocatura", value: $store.settings.blur, range: 0...5, step: 0.1, suffix: "", decimals: 1)
            HelpText("Un po' di nitidezza recupera i dettagli persi dopo un ridimensionamento forte.")
        }

        Button("Azzera le regolazioni") {
            var s = store.settings
            let defaults = ConversionSettings()
            s.rotation = defaults.rotation
            s.flipHorizontal = defaults.flipHorizontal
            s.flipVertical = defaults.flipVertical
            s.brightness = defaults.brightness
            s.contrast = defaults.contrast
            s.saturation = defaults.saturation
            s.sharpen = defaults.sharpen
            s.blur = defaults.blur
            s.grayscale = defaults.grayscale
            store.settings = s
        }
        .glassButton()
    }
}

// MARK: - Destinazione

private struct DestinationTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsGroup("Dove salvare") {
            Picker("Destinazione", selection: $store.settings.destination) {
                ForEach(DestinationMode.allCases) { Text($0.label).tag($0) }
            }

            switch store.settings.destination {
            case .subfolder:
                LabeledContent("Nome sottocartella") {
                    TextField("Comprimio", text: $store.settings.subfolderName)
                        .frame(width: 150)
                }
            case .customFolder:
                LabeledContent("Cartella") {
                    HStack(spacing: 6) {
                        Text(store.settings.customFolderPath.isEmpty
                             ? "Nessuna cartella scelta"
                             : store.settings.customFolderPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(store.settings.customFolderPath.isEmpty ? .secondary : .primary)
                        Button("Scegli…") { store.chooseDestinationFolder() }
                            .controlSize(.small)
                    }
                }
            case .sameFolder:
                WarningText("Con un suffisso vuoto e la sovrascrittura attiva, gli originali vengono sostituiti.")
            }
        }

        SettingsGroup("Nome del file") {
            LabeledContent("Prefisso") {
                TextField("", text: $store.settings.namePrefix).frame(width: 130)
            }
            LabeledContent("Suffisso") {
                TextField("es. -compresso", text: $store.settings.nameSuffix).frame(width: 130)
            }
            Toggle("Sovrascrivi i file esistenti", isOn: $store.settings.overwriteExisting)
            HelpText(exampleName)
        }

        SettingsGroup("ImageMagick") {
            if let install = store.install {
                LabeledContent("Versione") {
                    Text(install.version)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("Origine") {
                    HStack(spacing: 5) {
                        Image(systemName: install.source == .bundled ? "shippingbox.fill" : "terminal")
                            .foregroundStyle(install.source == .bundled ? Color.green : Color.secondary)
                        Text(install.source.label)
                            .font(.caption)
                    }
                }
                LabeledContent("Binario") {
                    Text(install.executable.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                if install.source == .bundled {
                    HelpText("Comprimio non richiede alcuna installazione: ImageMagick e i suoi "
                             + "coder sono dentro l'app.")
                }
            } else {
                WarningText("Nessuna installazione rilevata.")
            }
            HStack {
                Button("Scegli binario…") { store.chooseMagickBinary() }
                Button("Rileva di nuovo") { store.detectImageMagick() }
            }
            .controlSize(.small)
        }
    }

    private var exampleName: String {
        let sample = store.selectedItem?.url ?? URL(fileURLWithPath: "/foto.jpg")
        return "Esempio: " + ImageMagick.outputURL(for: sample, settings: store.settings).lastPathComponent
    }
}
