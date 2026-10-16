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
        }
    }
}
