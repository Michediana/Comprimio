//
//  CompactContentView.swift
//  Comprimio iOS
//
//  L'app per iPhone: una pila invece delle tre colonne dell'iPad. La lista
//  è la schermata principale, con Converti in fondo; un tocco su una riga
//  apre l'anteprima; le impostazioni sono un foglio, a mezza altezza, che
//  lascia vedere l'anteprima mentre cambia. Le immagini arrivano di solito
//  dalle Foto e ci tornano: dopo la conversione le azioni principali sono
//  «Salva nelle Foto» e «Condividi».
//

import SwiftUI

struct CompactContentView: View {
    @EnvironmentObject private var store: AppStore

    @State private var path: [ImageItem.ID] = []
    @State private var showsSettings = false

    var body: some View {
        NavigationStack(path: pathBinding) {
            FileListView(navigates: true)
                .navigationTitle("Comprimio")
                .toolbar { listToolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !store.items.isEmpty { CompactActionBar() }
                }
                .navigationDestination(for: ImageItem.ID.self) { _ in
                    CompactPreviewScreen(showsSettings: $showsSettings)
                }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettings = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            // A mezza altezza si tocca ancora ciò che sta sotto: si cambia
            // la qualità e si guarda l'anteprima aggiornarsi.
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        // Un file tolto dalla lista non può restare aperto nell'anteprima.
        .onChange(of: store.items.map(\.id)) { _, ids in
            path.removeAll { !ids.contains($0) }
        }
    }

    /// La selezione segue la pila nello stesso passaggio: aggiornarla dopo,
    /// in `onChange`, mostrerebbe per un attimo l'anteprima del file prima.
    private var pathBinding: Binding<[ImageItem.ID]> {
        Binding {
            path
        } set: { newPath in
            path = newPath
            if let id = newPath.last { store.selection = [id] }
        }
    }

    @ToolbarContentBuilder
    private var listToolbar: some ToolbarContent {
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showsSettings = true
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }

            // Un tocco apre le Foto, la sorgente di un telefono; tenendo
            // premuto si sceglie fra Foto, File e cartella.
            Menu {
                ImportMenuItems()
            } label: {
                Label("Add", systemImage: "plus")
            } primaryAction: {
                store.importRequest = .photos
            }
            .disabled(store.isProcessing)
        }
    }
}

/// In fondo alla lista: lo stato del batch e le azioni del momento.
/// Prima Converti; durante, Annulla; dopo, Salva nelle Foto e Condividi.
private struct CompactActionBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 10) {
            StatusContent(stacked: true)
            actions
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private var actions: some View {
        if store.isProcessing {
            Button(role: .cancel) {
                store.cancelProcessing()
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .glassButton()
        } else if !store.outputURLs.isEmpty {
            HStack(spacing: 10) {
                SaveToPhotosButton(ids: nil)
                    .glassButton(prominent: true)
                // Solo l'icona: con tre pulsanti «Salva nelle Foto» non
                // ci starebbe, e quella di Condividi si riconosce da sola.
                ShareLink(items: store.outputURLs) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .glassButton()
                // Dopo aver cambiato le impostazioni si riconverte da qui.
                Button {
                    store.startProcessing()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .glassButton()
                .disabled(!store.canProcess)
                .accessibilityLabel("Convert Again")
            }
        } else {
            Button {
                store.startProcessing()
            } label: {
                Text("Convert").frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            .disabled(!store.canProcess)
        }
    }
}

/// Salva nelle Foto i risultati fra `ids` (tutti, se `nil`). Quando sono
/// già tutti lì dice che è fatto, invece di sparire: con la destinazione
/// Foto li ha salvati il batch. Quelli che Foto ha rifiutato lo spenge e
/// basta: l'errore è già nella riga del file.
struct SaveToPhotosButton: View {
    @EnvironmentObject private var store: AppStore
    let ids: Set<ImageItem.ID>?

    var body: some View {
        let pending = store.outputsToSave(in: ids)
        let outputs = store.items.filter { $0.outputURL != nil && ids?.contains($0.id) ?? true }
        let allSaved = !outputs.isEmpty && outputs.allSatisfy { store.savedToPhotos.contains($0.id) }
        Button {
            store.saveOutputsToPhotos(ids)
        } label: {
            Group {
                if store.isSavingToPhotos {
                    ProgressView()
                } else if allSaved {
                    Label("Saved", systemImage: "checkmark")
                } else {
                    Label("Save to Photos", systemImage: "photo.badge.plus")
                }
            }
            // Accanto a Condividi e Riconverti, su un iPhone stretto.
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
        }
        .disabled(pending.isEmpty || store.isSavingToPhotos || store.isProcessing)
    }
}

/// L'anteprima di un file, aperta dalla lista. Il file è quello selezionato
/// nello store: la pila lo aggiorna prima di mostrare questa schermata.
private struct CompactPreviewScreen: View {
    @EnvironmentObject private var store: AppStore
    @Binding var showsSettings: Bool

    var body: some View {
        PreviewView()
            .navigationTitle(store.selectedItem?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let item = store.selectedItem, let output = item.outputURL, !store.isProcessing {
                    HStack(spacing: 10) {
                        SaveToPhotosButton(ids: [item.id])
                            .glassButton(prominent: true)
                        ShareLink(item: output) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                    .controlSize(.large)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.bar)
                }
            }
    }
}
