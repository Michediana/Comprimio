//
//  ContentView.swift
//  Comprimio iOS
//
//  L'app per iPad: la lista nella sidebar, l'anteprima nel dettaglio, le
//  impostazioni nell'inspector. Su iPhone `NavigationSplitView` si riduce a
//  una pila; il flusso pensato per l'iPhone arriva con la fase 5.
//

import MagickEngine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    @SceneStorage("showsSettings") private var showsSettings = true
    @State private var importer: ImportRequest?
    @State private var isPickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []

    var body: some View {
        NavigationSplitView {
            FileListView()
                .navigationTitle("Comprimio")
                .toolbar { sidebarToolbar }
        } detail: {
            PreviewView()
                .navigationTitle(store.selectedItem?.name ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar() }
                .toolbar { detailToolbar }
                .inspector(isPresented: $showsSettings) {
                    NavigationStack { SettingsView() }
                        .inspectorColumnWidth(min: 320, ideal: 370, max: 480)
                }
        }
        .fileImporter(
            isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
            allowedContentTypes: importer == .folder ? [.folder] : [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { store.add(urls: urls) }
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $photoSelection,
            matching: .images,
            // L'originale (HEIC, ProRAW…), non una copia ricodificata in JPEG.
            preferredItemEncoding: .current
        )
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            store.importPhotos(selection)
            photoSelection = []
        }
        // Le voci di menu (⌘O e simili) passano dallo store: i comandi
        // dell'app non vedono lo stato di questa vista.
        .onChange(of: store.importRequest) { _, request in
            guard let request else { return }
            store.importRequest = nil
            open(request)
        }
    }

    private func open(_ request: ImportRequest) {
        switch request {
        case .photos: isPickingPhotos = true
        case .files, .folder: importer = request
        }
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { open(.photos) } label: {
                    Label("From Photos…", systemImage: "photo.on.rectangle")
                }
                Button { open(.files) } label: {
                    Label("Add Images…", systemImage: "doc")
                }
                Button { open(.folder) } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(store.isProcessing)
        }
        ToolbarItem(placement: .topBarLeading) {
            if !store.items.isEmpty {
                Menu {
                    Button(role: .destructive) { store.removeAll() } label: {
                        Label("Clear List", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .disabled(store.isProcessing)
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if !store.outputURLs.isEmpty && !store.isProcessing {
                ShareLink(items: store.outputURLs) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            if store.isProcessing {
                Button("Cancel", role: .cancel) { store.cancelProcessing() }
            } else {
                // Testo e non icona: è l'azione principale, e nella barra
                // di iPadOS 26 un `Label` si riduce alla sola bacchetta.
                Button("Convert") { store.startProcessing() }
                    .glassButton(prominent: true)
                    .disabled(!store.canProcess)
            }

            Button {
                showsSettings.toggle()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
    }
}

/// Da dove importare, chiesto da un menu o da una scorciatoia.
enum ImportRequest: Hashable {
    case photos, files, folder
}

/// Barra in fondo al dettaglio: l'avanzamento durante il batch, l'esito
/// dopo, il riepilogo delle impostazioni a riposo.
private struct StatusBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if store.isProcessing {
                progressBars
            } else if let summary = store.lastRunSummary {
                HStack(spacing: 8) {
                    if !store.outputURLs.isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(summary).font(.callout)
                    Spacer(minLength: 0)
                    if let folder = store.appFolderInFiles {
                        Button("Show in Files") { openURL(folder) }
                    }
                }
            } else if store.install != nil, !store.items.isEmpty {
                Text(plan)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Sopra l'immagine su cui ImageMagick sta lavorando, sotto il batch.
    private var progressBars: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(
                value: store.focusedItem?.progress.fraction,
                leading: itemCaption,
                trailing: store.focusedItem.map { "\(Int($0.progress.fraction * 100))%" }
            )
            bar(
                value: store.batchProgress,
                leading: String(localized: "Batch"),
                trailing: "\(store.processedCount)/\(store.items.count)"
            )
        }
    }

    /// `value` nullo: la corsia è appena partita e non ha ancora riportato
    /// nulla, quindi la barra si muove senza indicare una frazione.
    private func bar(value: Double?, leading: String, trailing: String?) -> some View {
        HStack(spacing: 10) {
            Text(leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
            Group {
                if let value {
                    ProgressView(value: min(max(value, 0), 1))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            Text(trailing ?? "")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var itemCaption: String {
        guard let focused = store.focusedItem else { return String(localized: "Starting…") }
        var caption = "\(focused.progress.phase) \(focused.item.name)"
        let others = store.activeCount - 1
        if others > 0 { caption += " · +\(others)" }
        return caption
    }

    private var plan: String {
        let s = store.settings
        var parts: [String] = []
        parts.append(s.outputFormat == .keepOriginal
                     ? String(localized: "original format")
                     : s.outputFormat.label)
        if s.outputFormat.supportsQuality || s.outputFormat == .keepOriginal {
            parts.append(String(localized: "quality \(Int(s.quality))"))
        }
        if s.resizeMode != .none { parts.append(s.resizeMode.label) }
        switch store.destination {
        case .appFolder:
            parts.append(String(localized: "“\(s.subfolderName)” folder"))
        case .chosenFolder:
            let name = store.chosenFolderName ?? String(localized: "not set")
            parts.append(String(localized: "“\(name)” folder"))
        case .photos:
            parts.append(OutputDestination.photos.label)
        }
        return parts.joined(separator: " · ")
    }
}
