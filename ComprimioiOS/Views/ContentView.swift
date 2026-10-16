//
//  ContentView.swift
//  Comprimio iOS
//
//  Schermata provvisoria della fase 3: basta a provare sul dispositivo
//  l'AppStore e il motore (importazione, anteprima, conversione, annullamento).
//  L'interfaccia vera per iPad e iPhone arriva con le fasi 4 e 5.
//

import MagickEngine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isImporting = false

    /// I formati del gruppo principale che questo motore sa scrivere.
    private var formats: [OutputFormat] {
        [.keepOriginal] + OutputFormat.formats(in: .common).filter {
            $0 != .keepOriginal && store.install?.supports($0) == true
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $store.selection) {
                Section {
                    Picker("Output format", selection: $store.settings.outputFormat) {
                        ForEach(formats) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    if store.settings.outputFormat.supportsQuality || store.settings.outputFormat == .keepOriginal {
                        LabeledContent("Quality") {
                            Slider(value: $store.settings.quality, in: 1...100, step: 1)
                        }
                    }
                }

                if store.selectedItem != nil {
                    Section("Preview") { preview }
                }

                Section {
                    ForEach(store.items) { item in
                        row(item)
                    }
                } footer: {
                    if let summary = store.lastRunSummary { Text(summary) }
                }
            }
            .navigationTitle("Comprimio")
            .toolbar { toolbar }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.image, .folder],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { store.add(urls: urls) }
            }
            .safeAreaInset(edge: .bottom) {
                if store.isProcessing { progressBar }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Add Images", systemImage: "plus") { isImporting = true }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if store.isProcessing {
                Button("Cancel") { store.cancelProcessing() }
            } else {
                Button("Convert") { store.startProcessing() }
                    .disabled(store.items.isEmpty || !store.isFormatSupported)
            }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Remove", systemImage: "trash", role: .destructive) { store.removeAll() }
                .disabled(store.items.isEmpty || store.isProcessing)
        }
    }

    private func row(_ item: ImageItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: item.status.symbol)
                Text(item.name).lineLimit(1)
                Spacer()
                Text(Fmt.bytes(item.originalSize))
                if item.outputSize != nil {
                    Text("→ \(Fmt.bytes(item.outputSize)) (\(Fmt.percent(item.saving)))")
                }
            }
            if let error = item.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .tag(item.id)
    }

    private var preview: some View {
        HStack(alignment: .top) {
            pane("Original", image: store.previewOriginal, caption: Fmt.pixels(store.selectedItem?.pixelSize))
            pane("Result", image: store.previewResult,
                 caption: "\(Fmt.bytes(store.previewResultSize)) · \(Fmt.pixels(store.previewPixelSize))")
        }
        .overlay {
            if store.isRenderingPreview { ProgressView() }
        }
        .overlay(alignment: .bottom) {
            if let error = store.previewError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func pane(_ title: LocalizedStringKey, image: CGImage?, caption: String) -> some View {
        VStack {
            Text(title).font(.caption.bold())
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.secondary.opacity(0.1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 240)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: store.batchProgress)
            if let focused = store.focusedItem {
                Text("\(focused.item.name): \(focused.progress.phase)")
                    .font(.caption).lineLimit(1)
                ProgressView(value: focused.progress.fraction)
            }
        }
        .padding()
        .background(.bar)
    }
}
