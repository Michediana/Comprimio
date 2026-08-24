//
//  ComprimioApp.swift
//  Comprimio
//
//  Created by Michele Diana on 24/08/2026.
//

import AppKit
import SwiftUI

/// Gestisce l'apertura di file dal Finder («Apri con», trascinamento sul Dock,
/// `open -a Comprimio foto.jpg`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppStore.shared.add(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ComprimioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Aggiungi immagini…") {
                    store.presentOpenPanel(directories: false)
                }
                .keyboardShortcut("o")

                Button("Aggiungi cartella…") {
                    store.presentOpenPanel(directories: true)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Elabora") {
                Button("Converti") { store.startProcessing() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.items.isEmpty || store.install == nil || store.isProcessing)

                Button("Annulla elaborazione") { store.cancelProcessing() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.isProcessing)

                Divider()

                Button("Aggiorna anteprima") { store.refreshPreview() }
                    .keyboardShortcut("r")

                Button("Svuota lista") { store.removeAll() }
                    .disabled(store.items.isEmpty)
            }
        }
    }
}
