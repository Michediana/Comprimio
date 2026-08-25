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
                Label("Add Images", systemImage: "plus")
            }
            .help("Add Images")

            Button {
                store.presentOpenPanel(directories: true)
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .help("Add a folder, including its subfolders")

            Button {
                store.removeSelected()
            } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .disabled(store.selection.isEmpty)
            .help("Remove the selected items from the list")

            Button {
                store.removeAll()
            } label: {
                Label("Clear List", systemImage: "trash")
            }
            .disabled(store.items.isEmpty)
            .help("Clear the list")
        }

        ToolbarItemGroup {
            Button {
                store.refreshPreview()
            } label: {
                Label("Refresh Preview", systemImage: "arrow.clockwise")
            }
            .disabled(store.items.isEmpty || store.install == nil)
            .help("Regenerate the preview")

            Button {
                store.revealOutputInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .disabled(store.items.allSatisfy { $0.outputURL == nil })
            .help("Show the produced files in the Finder")
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
                Text("ImageMagick not available")
                    .font(.headline)
                Text(store.installError ?? String(localized: "Install ImageMagick to process images."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button("Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(installCommand, forType: .string)
                    }
                    Button("Choose Binary…") { store.chooseMagickBinary() }
                    Button("Try Again") { store.detectImageMagick() }
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
