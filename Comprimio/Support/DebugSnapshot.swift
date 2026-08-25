//
//  DebugSnapshot.swift
//  Comprimio
//
//  Solo per lo sviluppo: cattura la finestra in PNG senza passare da
//  «Registrazione schermo». Si attiva con la variabile d'ambiente
//  COMPRIMIO_SNAPSHOT=/percorso/cartella (facoltativa COMPRIMIO_TABS=conversion,resize).
//

#if DEBUG
import AppKit
import SwiftUI

extension Notification.Name {
    static let debugSelectTab = Notification.Name("ComprimioDebugSelectTab")
}

enum DebugSnapshot {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["COMPRIMIO_SNAPSHOT"] else { return }
        let tabs = (env["COMPRIMIO_TABS"] ?? "conversion,resize,adjust,watermark,destination")
            .split(separator: ",")
            .map(String.init)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            for tab in tabs {
                NotificationCenter.default.post(name: .debugSelectTab, object: tab)
                try? await Task.sleep(nanoseconds: 700_000_000)
                capture(to: URL(fileURLWithPath: directory).appendingPathComponent("\(tab).png"))
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func capture(to url: URL) {
        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}
#endif
