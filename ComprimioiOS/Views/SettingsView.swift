//
//  SettingsView.swift
//  Comprimio iOS
//
//  Le cinque schede del Mac (Conversione, Ridimensiona, Regolazioni,
//  Filigrana, Destinazione) nell'inspector dell'iPad. Le opzioni sono le
//  stesse; cambiano la scelta dei file e la destinazione.
//

import SwiftUI
import UniformTypeIdentifiers

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

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @SceneStorage("settingsTab") private var tab: SettingsTab = .conversion

    var body: some View {
        Form {
            switch tab {
            case .conversion: ConversionTab()
            case .resize: ResizeTab()
            case .adjust: AdjustTab()
            case .watermark: WatermarkTab()
            case .destination: DestinationTab()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            // Cinque etichette nella larghezza dell'inspector non ci stanno:
            // solo icone, con il nome della scheda come titolo.
            Picker("Settings", selection: $tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Image(systemName: tab.icon)
                        .accessibilityLabel(tab.label)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle(tab.label)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
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
            .pickerStyle(.menu)

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
                    step: 1
                )
                .disabled(store.settings.lossless && format.supportsLossless)
                .onChange(of: format.maxQuality) { _, limit in
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
                    value: intBinding(\.pngCompressionLevel),
                    range: 0...9,
                    step: 1
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
                    value: intBinding(\.webpMethod),
                    range: 0...6,
                    step: 1
                )
            }
        }

        if format.family == .jxl {
            SettingsGroup("JPEG XL options") {
                ValueSlider(
                    title: "Effort (slower = smaller)",
                    value: intBinding(\.jxlEffort),
                    range: 1...9,
                    step: 1
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

    private func intBinding(_ keyPath: WritableKeyPath<ConversionSettings, Int>) -> Binding<Double> {
        Binding(
            get: { Double(store.settings[keyPath: keyPath]) },
            set: { store.settings[keyPath: keyPath] = Int($0) }
        )
    }

    /// Solo ciò che questo motore sa scrivere, più il formato già scelto,
    /// che altrimenti sparirebbe dal menu senza spiegazione.
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
            ValueSlider(title: "Brightness", value: $store.settings.brightness, range: -100...100, step: 1)
            ValueSlider(title: "Contrast", value: $store.settings.contrast, range: -100...100, step: 1)
            ValueSlider(title: "Saturation", value: $store.settings.saturation, range: -100...100, step: 1)
                .disabled(store.settings.grayscale)
            Toggle("Grayscale", isOn: $store.settings.grayscale)
        }

        SettingsGroup("Detail") {
            ValueSlider(title: "Sharpen", value: $store.settings.sharpen, range: 0...5, step: 0.1, decimals: 1)
            ValueSlider(title: "Blur", value: $store.settings.blur, range: 0...5, step: 0.1, decimals: 1)
            HelpText("A little sharpening recovers detail lost after a heavy downscale.")
        }

        Section {
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
        }
    }
}

// MARK: - Filigrana

private struct WatermarkTab: View {
    @EnvironmentObject private var store: AppStore
    @State private var isChoosingLogo = false

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
                    Text(watermark.imagePath.isEmpty
                         ? String(localized: "No file chosen")
                         : (watermark.imageURL?.lastPathComponent ?? watermark.imagePath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(watermark.imagePath.isEmpty ? .secondary : .primary)
                }
                Button("Choose…") { isChoosingLogo = true }
                if !watermark.imagePath.isEmpty {
                    Button("Remove", role: .destructive) { store.settings.watermark.imagePath = "" }
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
            .fileImporter(isPresented: $isChoosingLogo, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { store.setWatermarkImage(url) }
            }
        }

        if watermark.mode == .text {
            SettingsGroup("Text") {
                LabeledContent("Text") {
                    TextBox(text: $store.settings.watermark.text, placeholder: "© Studio 2026", width: 180)
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
    @State private var isChoosingFolder = false

    var body: some View {
        SettingsGroup("Where to save") {
            Picker("Destination", selection: $store.destination) {
                ForEach(OutputDestination.allCases) { destination in
                    Label(destination.label, systemImage: destination.symbol).tag(destination)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            switch store.destination {
            case .appFolder:
                LabeledContent("Folder name") {
                    TextBox(text: $store.settings.subfolderName, placeholder: "Comprimio", width: 160)
                }
                if UIDevice.current.userInterfaceIdiom == .phone {
                    HelpText("In Files, under On My iPhone › Comprimio.")
                } else {
                    HelpText("In Files, under On My iPad › Comprimio.")
                }
            case .chosenFolder:
                LabeledContent("Folder") {
                    Text(store.chosenFolderName ?? String(localized: "No folder chosen"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(store.chosenFolderName == nil ? .secondary : .primary)
                }
                Button("Choose…") { isChoosingFolder = true }
            case .photos:
                HelpText("""
                    Each converted image is added to the library as a new photo. Photos \
                    only accepts the formats it can display, such as JPEG, HEIC, PNG and TIFF.
                    """)
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.setOutputFolder(url) }
        }

        SettingsGroup("File name") {
            LabeledContent("Prefix") {
                TextBox(text: $store.settings.namePrefix, placeholder: String(localized: "e.g. web-"), width: 180)
            }
            LabeledContent("Suffix") {
                TextBox(text: $store.settings.nameSuffix, placeholder: String(localized: "e.g. -compressed"), width: 180)
            }
            if store.destination != .photos {
                Toggle("Overwrite existing files", isOn: $store.settings.overwriteExisting)
            }
            HelpText(verbatim: exampleName)
        }

        SettingsGroup("ImageMagick") {
            if let install = store.install {
                LabeledContent("Version") {
                    Text(install.version)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                HelpText("""
                    Comprimio needs no installation: ImageMagick and its coders live \
                    inside the app.
                    """)
            }
        }
    }

    private var exampleName: String {
        let sample = store.selectedItem?.url ?? URL(fileURLWithPath: "/foto.jpg")
        let name = ImageMagick.outputURL(for: sample, settings: store.settings).lastPathComponent
        return String(localized: "Example: \(name)")
    }
}
