//
//  FileListPane.swift
//  Comprimio
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileListPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            table
                .overlay {
                    if store.items.isEmpty { EmptyListPlaceholder() }
                }
                .contentPanel()
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                }

            listFooter
        }
        .padding(12)
    }

    private var table: some View {
        Table(store.items, selection: $store.selection, sortOrder: $store.sortOrder) {
            TableColumn("Nome", value: \.name) { item in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                }
                .help(item.url.path)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Dimensione", value: \.originalSize) { item in
                Text(Fmt.bytes(item.originalSize)).monospacedDigit()
            }
            .width(min: 80, ideal: 96)

            TableColumn("Risoluzione", value: \.sortPixels) { item in
                Text(Fmt.pixels(item.pixelSize)).monospacedDigit()
            }
            .width(min: 90, ideal: 110)

            TableColumn("Risultato", value: \.sortOutputSize) { item in
                Text(Fmt.bytes(item.outputSize)).monospacedDigit()
            }
            .width(min: 80, ideal: 96)

            TableColumn("Risparmio", value: \.sortSaving) { item in
                SavingLabel(saving: item.saving)
            }
            .width(min: 80, ideal: 90)

            TableColumn("Stato") { item in
                StatusLabel(item: item)
            }
            .width(min: 90, ideal: 110)
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .onChange(of: store.sortOrder) { _ in store.applySort() }
        .contextMenu(forSelectionType: ImageItem.ID.self) { ids in
            Button("Rimuovi dalla lista") {
                store.items.removeAll { ids.contains($0.id) }
                store.selection.subtract(ids)
            }
            Button("Mostra originale nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(Array(ids))
            }
            let outputs = store.items.filter { ids.contains($0.id) }.compactMap(\.outputURL)
            Button("Mostra risultato nel Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
            }
            .disabled(outputs.isEmpty)
        }
    }

    private var listFooter: some View {
        HStack(spacing: 10) {
            Text("\(store.items.count) immagini")
                .font(.callout)
            if store.totalOriginalSize > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text(Fmt.bytes(store.totalOriginalSize))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if !store.selection.isEmpty {
                Text("\(store.selection.count) selezionate")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .padding(.horizontal, 2)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURL() { urls.append(url) }
            }
            await MainActor.run { store.add(urls: urls) }
        }
        return true
    }
}

struct SavingLabel: View {
    let saving: Double?

    var body: some View {
        if let saving {
            Text(Fmt.percent(saving))
                .monospacedDigit()
                .foregroundStyle(saving >= 0 ? Color.green : Color.orange)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct StatusLabel: View {
    let item: ImageItem

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.status.symbol)
                .foregroundStyle(color)
            Text(item.status == .failed ? "Errore" : item.status.label)
                .lineLimit(1)
        }
        .help(item.errorMessage ?? item.status.label)
    }

    private var color: Color {
        switch item.status {
        case .pending: return .secondary
        case .processing: return .accentColor
        case .done: return .green
        case .failed: return .red
        }
    }
}

struct EmptyListPlaceholder: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nessuna immagine")
                .font(.title3.weight(.medium))
            Text("Trascina qui i file o le cartelle da elaborare.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Aggiungi immagini…") {
                store.presentOpenPanel(directories: false)
            }
            .glassButton(prominent: true)
            .padding(.top, 4)
        }
        .padding(24)
    }
}

extension NSItemProvider {
    /// Estrae un URL di file da un provider di drag & drop.
    func fileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}
