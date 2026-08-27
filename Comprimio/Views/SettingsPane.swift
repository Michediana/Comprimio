//
//  SettingsPane.swift
//  Comprimio
//
//  Colonna destra a schede: Conversione, Ridimensiona, Regolazioni,
//  Filigrana, Destinazione.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case conversion, resize, adjust, watermark, destination

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conversion: return String(localized: "Conversion")
        case .resize: return String(localized: "Resize")
        case .adjust: return String(localized: "Adjust")
        case .watermark: return String(localized: "Watermark")
        case .destination: return String(localized: "Destination")
        }
    }

    var icon: String {
        switch self {
        case .conversion: return "arrow.2.squarepath"
        case .resize: return "aspectratio"
        case .adjust: return "slider.horizontal.3"
        case .watermark: return "signature"
        case .destination: return "folder"
        }
    }
}

/// Barra delle schede con icona e didascalia impilate.
///
/// A cinque voci il `Picker` segmentato non basta più: nella colonna al minimo
/// della sua larghezza le etichette venivano troncate a «Conve…».
private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14))
                        Text(tab.label)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.label)
            }
        }
    }
}

struct SettingsPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab: SettingsTab = .conversion

    var body: some View {
        VStack(spacing: 10) {
            SettingsTabBar(selection: $tab)

            Form {
                switch tab {
                case .conversion: ConversionTab()
                case .resize: ResizeTab()
                case .adjust: AdjustTab()
                case .watermark: WatermarkTab()
                case .destination: DestinationTab()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentPanel()
        }
        .padding(12)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugSelectTab)) { note in
            if let raw = note.object as? String, let selected = SettingsTab(rawValue: raw) {
                tab = selected
            }
        }
        #endif
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
        SettingsGroup("Output format") {
            Picker("Format", selection: $store.settings.outputFormat) {
                Text(OutputFormat.keepOriginal.label).tag(OutputFormat.keepOriginal)
                ForEach(availableGroups, id: \.category) { group in
                    Section(group.category.label) {
                        ForEach(group.formats) { Text($0.label).tag($0) }
                    }
                }
            }

            if store.settings.outputFormat == .keepOriginal {
                HelpText("Every image keeps its own format; only the quality and the options chosen below change.")
            } else if let install = store.install, !install.supports(store.settings.outputFormat) {
                WarningText("This ImageMagick installation cannot write \(store.settings.outputFormat.label).")
            }
        }

        SettingsGroup("Compression") {
            if format.supportsLossless {
                Toggle("Lossless", isOn: $store.settings.lossless)
            }

            if format.supportsQuality {
                ValueSlider(
                    title: "Quality",
                    value: $store.settings.quality,
                    range: 1...Double(format.maxQuality),
                    step: 1,
                    suffix: ""
                )
                .disabled(store.settings.lossless && format.supportsLossless)
                .onChange(of: format.maxQuality) { limit in
                    store.settings.quality = min(store.settings.quality, Double(limit))
                }
                HelpText(verbatim: qualityHint)
                if format == .avif {
                    HelpText("AVIF stops at quality 99: the bundled encoder cannot produce lossless AVIF.")
                }
            } else {
                HelpText("\(format.label) has no quality setting.")
            }

            Toggle("Keep metadata (EXIF, IPTC, XMP)", isOn: $store.settings.keepMetadata)
            Toggle("Convert to sRGB", isOn: $store.settings.convertToSRGB)
        }

        if format.family == .jpeg {
            SettingsGroup("JPEG options") {
                Toggle("Progressive JPEG", isOn: $store.settings.jpegProgressive)
                Picker("Chroma subsampling", selection: $store.settings.chromaSubsampling) {
                    ForEach(ChromaSubsampling.allCases) { Text($0.label).tag($0) }
                }
                HelpText("4:2:0 reduces file size; 4:4:4 preserves color detail (text, graphics).")
            }
        }

        if format.family == .png {
            SettingsGroup("PNG options") {
                ValueSlider(
                    title: "Compression level",
                    value: Binding(
                        get: { Double(store.settings.pngCompressionLevel) },
                        set: { store.settings.pngCompressionLevel = Int($0) }
                    ),
                    range: 0...9,
                    step: 1,
                    suffix: ""
                )
                if format == .png {
                    Toggle("8-bit palette (PNG8)", isOn: $store.settings.pngPalette)
                    HelpText("PNG8 greatly reduces file size on images with few colors.")
                }
            }
        }

        if format.family == .webp {
            SettingsGroup("WebP options") {
                ValueSlider(
                    title: "Method (slower = smaller)",
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

        if format.family == .jxl {
            SettingsGroup("JPEG XL options") {
                ValueSlider(
                    title: "Effort (slower = smaller)",
                    value: Binding(
                        get: { Double(store.settings.jxlEffort) },
                        set: { store.settings.jxlEffort = Int($0) }
                    ),
                    range: 1...9,
                    step: 1,
                    suffix: ""
                )
                HelpText("""
                    Effort only affects encoding time. “Lossless” matches quality 100: \
                    larger than a compressed JPEG XL, but far smaller than a PNG.
                    """)
            }
        }

        SettingsGroup("Transparency") {
            Toggle("Flatten onto a background color", isOn: $store.settings.flattenAlpha)
                .disabled(!format.supportsAlpha)
            HexColorField(hex: $store.settings.flattenColorHex)
                .disabled(!store.settings.flattenAlpha && format.supportsAlpha)
            if !format.supportsAlpha {
                HelpText("\(format.label) does not support transparency: it is flattened automatically.")
            }
        }
    }

    /// Il menu elenca solo ciò che questa installazione sa davvero scrivere:
    /// il catalogo comprende formati che dipendono da delegate opzionali
    /// (JPEG XL, JPEG 2000, OpenEXR) e mostrarli tutti significherebbe offrire
    /// scelte che poi falliscono. Il formato già selezionato resta comunque
    /// visibile, altrimenti sparirebbe dal menu senza spiegazione.
    private var availableGroups: [(category: FormatCategory, formats: [OutputFormat])] {
        let selected = store.settings.outputFormat
        return FormatCategory.allCases.compactMap { category in
            let formats = OutputFormat.formats(in: category).filter { option in
                guard let install = store.install else { return true }
                return install.supports(option) || option == selected
            }
            return formats.isEmpty ? nil : (category, formats)
        }
    }

    private var qualityHint: String {
        let q = Int(store.settings.quality)
        switch q {
        case 90...100: return String(localized: "Top quality, little saving.")
        case 75..<90: return String(localized: "Recommended trade-off for the web.")
        case 50..<75: return String(localized: "Smaller files, artifacts visible on fine detail.")
        default: return String(localized: "Aggressive compression: heavy quality loss.")
        }
    }
}

// MARK: - Ridimensiona

private struct ResizeTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsGroup("Resizing") {
            Picker("Mode", selection: $store.settings.resizeMode) {
                ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
            }

            switch store.settings.resizeMode {
            case .none:
                HelpText("The pixel dimensions stay unchanged.")
            case .percent:
                ValueSlider(title: "Scale", value: $store.settings.percent, range: 1...400, step: 1, suffix: "%")
            case .fit, .exact, .fill:
                IntField(title: "Width", value: $store.settings.width, suffix: "px")
                IntField(title: "Height", value: $store.settings.height, suffix: "px")
            case .width:
                IntField(title: "Width", value: $store.settings.width, suffix: "px")
            case .height:
                IntField(title: "Height", value: $store.settings.height, suffix: "px")
            }

            if store.settings.resizeMode != .none {
                if store.settings.resizeMode != .exact && store.settings.resizeMode != .fill {
                    Toggle("Do not enlarge smaller images", isOn: $store.settings.doNotEnlarge)
                }
                Picker("Resampling filter", selection: $store.settings.resizeFilter) {
                    ForEach(ResizeFilter.allCases) { Text($0.label).tag($0) }
                }
                HelpText(verbatim: hint)
            }
        }

        SettingsGroup("Print resolution") {
            Toggle("Set DPI", isOn: $store.settings.applyDPI)
            IntField(title: "DPI", value: $store.settings.dpi, suffix: "ppi")
                .disabled(!store.settings.applyDPI)
            HelpText("Changes only the density metadata, not the number of pixels.")
        }
    }

    private var hint: String {
        switch store.settings.resizeMode {
        case .fit: return String(localized: "The image fits inside the box, keeping its aspect ratio.")
        case .fill: return String(localized: "The image covers the box and is cropped at the center.")
        case .exact: return String(localized: "The aspect ratio is not preserved: the image may be distorted.")
        default: return String(localized: "The original aspect ratio is preserved.")
        }
    }
}

// MARK: - Regolazioni

private struct AdjustTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsGroup("Orientation") {
            Toggle("Apply the EXIF orientation", isOn: $store.settings.autoOrient)
            Picker("Rotation", selection: $store.settings.rotation) {
                ForEach(Rotation.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Flip horizontally", isOn: $store.settings.flipHorizontal)
            Toggle("Flip vertically", isOn: $store.settings.flipVertical)
        }

        SettingsGroup("Color") {
            ValueSlider(title: "Brightness", value: $store.settings.brightness, range: -100...100, step: 1, suffix: "")
            ValueSlider(title: "Contrast", value: $store.settings.contrast, range: -100...100, step: 1, suffix: "")
            ValueSlider(title: "Saturation", value: $store.settings.saturation, range: -100...100, step: 1, suffix: "")
                .disabled(store.settings.grayscale)
            Toggle("Grayscale", isOn: $store.settings.grayscale)
        }

        SettingsGroup("Detail") {
            ValueSlider(title: "Sharpen", value: $store.settings.sharpen, range: 0...5, step: 0.1, suffix: "", decimals: 1)
            ValueSlider(title: "Blur", value: $store.settings.blur, range: 0...5, step: 0.1, suffix: "", decimals: 1)
            HelpText("A little sharpening recovers detail lost after a heavy downscale.")
        }

        Button("Reset adjustments") {
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

// MARK: - Filigrana

private struct WatermarkTab: View {
    @EnvironmentObject private var store: AppStore

    private var watermark: WatermarkSettings { store.settings.watermark }

    var body: some View {
        SettingsGroup("Watermark") {
            Picker("Type", selection: $store.settings.watermark.mode) {
                ForEach(WatermarkMode.allCases) { Text($0.label).tag($0) }
            }
            if watermark.mode == .none {
                HelpText("No overlay: the images come out as they are.")
            }
        }

        if watermark.mode == .image {
            SettingsGroup("Logo") {
                LabeledContent("File") {
                    HStack(spacing: 6) {
                        Text(watermark.imagePath.isEmpty
                             ? String(localized: "No file chosen")
                             : (watermark.imageURL?.lastPathComponent ?? watermark.imagePath))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(watermark.imagePath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { store.chooseWatermarkImage() }
                            .controlSize(.small)
                        if !watermark.imagePath.isEmpty {
                            Button("Remove") { store.settings.watermark.imagePath = "" }
                                .controlSize(.small)
                        }
                    }
                }
                ValueSlider(
                    title: "Width",
                    value: $store.settings.watermark.imageScale,
                    range: 1...100,
                    step: 1,
                    suffix: "%"
                )
                HelpText("""
                    A percentage of the image width, so the same logo stays in proportion \
                    across files of different sizes. A PNG with a transparent background \
                    gives the best result.
                    """)
            }
        }

        if watermark.mode == .text {
            SettingsGroup("Text") {
                LabeledContent("Text") {
                    TextBox(text: $store.settings.watermark.text, placeholder: "© Studio 2026", width: 190)
                }
                Picker("Font", selection: $store.settings.watermark.fontFamily) {
                    ForEach(WatermarkSettings.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                HexColorField(title: "Color", hex: $store.settings.watermark.colorHex)
                Toggle("Dark outline", isOn: $store.settings.watermark.outline)
                ValueSlider(
                    title: "Font size",
                    value: $store.settings.watermark.textScale,
                    range: 1...25,
                    step: 0.5,
                    suffix: "%",
                    decimals: 1
                )
                HelpText("""
                    The font size is a percentage of the image width. The outline keeps \
                    the text readable even over a light area.
                    """)
            }
        }

        if watermark.mode != .none {
            SettingsGroup("Placement") {
                Toggle("Tile across the whole image", isOn: $store.settings.watermark.tile)

                if watermark.tile {
                    ValueSlider(
                        title: "Gap between repeats",
                        value: $store.settings.watermark.tileGap,
                        range: 0...300,
                        step: 5,
                        suffix: "%"
                    )
                    HelpText("A percentage of the watermark size.")
                } else {
                    PositionGrid(selection: $store.settings.watermark.position)
                    ValueSlider(
                        title: "Margin from the edge",
                        value: $store.settings.watermark.margin,
                        range: 0...20,
                        step: 0.5,
                        suffix: "%",
                        decimals: 1
                    )
                    .disabled(watermark.position == .center)
                }

                ValueSlider(
                    title: "Rotation",
                    value: $store.settings.watermark.rotation,
                    range: -90...90,
                    step: 5,
                    suffix: "°"
                )
            }

            SettingsGroup("Rendering") {
                ValueSlider(
                    title: "Opacity",
                    value: $store.settings.watermark.opacity,
                    range: 5...100,
                    step: 1,
                    suffix: "%"
                )
                if let problem = watermark.problem {
                    WarningText(verbatim: problem)
                } else {
                    HelpText("""
                        The watermark is applied after resizing and color adjustments: it stays \
                        in proportion to the final image, and a color logo is left untouched by \
                        the grayscale conversion.
                        """)
                }
            }
        }
    }
}

// MARK: - Destinazione

private struct DestinationTab: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        SettingsGroup("Where to save") {
            Picker("Destination", selection: $store.settings.destination) {
                ForEach(DestinationMode.allCases) { Text($0.label).tag($0) }
            }

            switch store.settings.destination {
            case .subfolder:
                LabeledContent("Subfolder name") {
                    TextBox(text: $store.settings.subfolderName, placeholder: "Comprimio", width: 150)
                }
            case .customFolder:
                LabeledContent("Folder") {
                    HStack(spacing: 6) {
                        Text(store.settings.customFolderPath.isEmpty
                             ? String(localized: "No folder chosen")
                             : store.settings.customFolderPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(store.settings.customFolderPath.isEmpty ? .secondary : .primary)
                        Button("Choose…") { store.chooseDestinationFolder() }
                            .controlSize(.small)
                    }
                }
            case .sameFolder:
                WarningText("With an empty suffix and overwriting enabled, the originals are replaced.")
            }
        }

        SettingsGroup("File name") {
            LabeledContent("Prefix") {
                TextBox(text: $store.settings.namePrefix, placeholder: String(localized: "e.g. web-"), width: 200)
            }
            LabeledContent("Suffix") {
                TextBox(text: $store.settings.nameSuffix, placeholder: String(localized: "e.g. -compressed"), width: 200)
            }
            Toggle("Overwrite existing files", isOn: $store.settings.overwriteExisting)
            HelpText(verbatim: exampleName)
        }

        SettingsGroup("ImageMagick") {
            if let install = store.install {
                LabeledContent("Version") {
                    Text(install.version)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                LabeledContent("Binary") {
                    Text(install.executable.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
                HelpText("""
                    Comprimio needs no installation: ImageMagick and its coders live \
                    inside the app.
                    """)
            } else {
                WarningText("No installation detected.")
            }
            HStack {
                Button("Detect Again") { store.detectImageMagick() }
            }
            .controlSize(.small)
        }
    }

    private var exampleName: String {
        let sample = store.selectedItem?.url ?? URL(fileURLWithPath: "/foto.jpg")
        let name = ImageMagick.outputURL(for: sample, settings: store.settings).lastPathComponent
        return String(localized: "Example: \(name)")
    }
}
