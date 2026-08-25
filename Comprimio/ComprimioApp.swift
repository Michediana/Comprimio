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

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        DebugSnapshot.runIfRequested()
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppStore.shared.cancelAllWork() }
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
                Button("Add Images…") {
                    store.presentOpenPanel(directories: false)
                }
                .keyboardShortcut("o")

                Button("Add Folder…") {
                    store.presentOpenPanel(directories: true)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Process") {
                Button("Convert") { store.startProcessing() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store.items.isEmpty || store.install == nil || store.isProcessing)

                Button("Cancel Processing") { store.cancelProcessing() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!store.isProcessing)

                Divider()

                Button("Refresh Preview") { store.refreshPreview() }
                    .keyboardShortcut("r")

                Button("Clear List") { store.removeAll() }
                    .disabled(store.items.isEmpty)
            }
        }
    }
}
