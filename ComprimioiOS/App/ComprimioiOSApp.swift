//
//  ComprimioiOSApp.swift
//  Comprimio iOS
//

import SwiftUI

@main
struct ComprimioiOSApp: App {
    @StateObject private var store = AppStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                // «Apri con» e «Condividi › Comprimio» da File e da altre app.
                // Con LSSupportsOpeningDocumentsInPlace l'URL è l'originale,
                // security-scoped: `add(urls:)` ne apre l'accesso.
                .onOpenURL { url in store.add(urls: [url]) }
        }
        // Con una tastiera: le stesse scorciatoie del Mac. Su iPadOS 26
        // compaiono anche nella barra dei menu.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Images…") { store.importRequest = .files }
                    .keyboardShortcut("o")
                Button("Add Folder…") { store.importRequest = .folder }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("From Photos…") { store.importRequest = .photos }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }

            CommandMenu("Process") {
                Button("Convert") { store.startProcessing() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canProcess)

                Button("Cancel Processing") { store.cancelProcessing() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.isProcessing)

                Divider()

                Button("Refresh Preview") { store.refreshPreview() }
                    .keyboardShortcut("r")

                Button("Clear List") { store.removeAll() }
                    .disabled(store.items.isEmpty || store.isProcessing)
            }
        }
    }
}
