//
//  ContentView.swift
//  Comprimio
//

import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if store.install == nil {
                MagickMissingBanner()
                    .padding(12)
            }

            VSplitView {
                VStack(spacing: 0) {
                    HSplitView {
                        FileListPane()
                            .frame(minWidth: 380, idealWidth: 640)
                        SettingsPane()
                            .frame(minWidth: 330, idealWidth: 380, maxWidth: 560)
                    }
                    .frame(minHeight: 240)

                    Divider()
                    ActionBar()
                }

                PreviewPane()
                    .frame(minHeight: 170, idealHeight: 280)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar { toolbarContent }
        .navigationTitle("Comprimio")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.presentOpenPanel(directories: false)
            } label: {
                Label("Aggiungi immagini", systemImage: "plus")
            }
            .help("Aggiungi immagini")

            Button {
                store.presentOpenPanel(directories: true)
            } label: {
                Label("Aggiungi cartella", systemImage: "folder.badge.plus")
            }
            .help("Aggiungi una cartella, incluse le sottocartelle")

            Button {
                store.removeSelected()
            } label: {
                Label("Rimuovi", systemImage: "minus.circle")
            }
            .disabled(store.selection.isEmpty)
            .help("Rimuovi dalla lista gli elementi selezionati")

            Button {
                store.removeAll()
            } label: {
                Label("Svuota lista", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
            .help("Svuota la lista")
        }

        ToolbarItemGroup {
            Button {
                store.refreshPreview()
            } label: {
                Label("Aggiorna anteprima", systemImage: "arrow.clockwise")
            }
            .disabled(store.items.isEmpty || store.install == nil)
            .help("Rigenera l'anteprima")

            Button {
                store.revealOutputInFinder()
            } label: {
                Label("Mostra nel Finder", systemImage: "folder")
            }
            .disabled(store.items.allSatisfy { $0.outputURL == nil })
            .help("Mostra i file prodotti nel Finder")
        }
    }
}

/// Banner mostrato quando il binario `magick` non è disponibile.
struct MagickMissingBanner: View {
    @EnvironmentObject private var store: AppStore

    private let installCommand = "brew install imagemagick"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 6) {
                Text("ImageMagick non disponibile")
                    .font(.headline)
                Text(store.installError ?? "Installa ImageMagick per elaborare le immagini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Copia comando") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    }
                    Button("Scegli binario…") { store.chooseMagickBinary() }
                    Button("Riprova") { store.detectImageMagick() }
                }
                .controlSize(.small)
                .glassButton()
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassSurface(cornerRadius: 14)
    }
}
