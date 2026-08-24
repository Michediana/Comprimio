//
//  ActionBar.swift
//  Comprimio
//

import SwiftUI

struct ActionBar: View {
    @EnvironmentObject private var store: AppStore

    private var canRun: Bool {
        !store.items.isEmpty && store.install != nil && !store.isProcessing
    }

    var body: some View {
        HStack(spacing: 10) {
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        store.presentOpenPanel(directories: false)
                    } label: {
                        Label("Aggiungi…", systemImage: "plus")
                    }

                    Button {
                        store.removeSelected()
                    } label: {
                        Label("Rimuovi", systemImage: "minus")
                    }
                    .disabled(store.selection.isEmpty)
                }
                .glassButton()
            }

            Spacer(minLength: 12)

            status

            Spacer(minLength: 12)

            if store.isProcessing {
                Button("Annulla") { store.cancelProcessing() }
                    .glassButton()
            }

            Button {
                store.startProcessing()
            } label: {
                Label(
                    store.isProcessing ? "Elaborazione…" : "Converti",
                    systemImage: store.isProcessing ? "hourglass" : "wand.and.stars"
                )
                .padding(.horizontal, 4)
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canRun)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if store.isProcessing {
            HStack(spacing: 8) {
                ProgressView(value: Double(store.processedCount), total: Double(max(store.items.count, 1)))
                    .frame(width: 160)
                Text("\(store.processedCount)/\(store.items.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if let summary = store.lastRunSummary {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(summary).font(.callout)
                Button("Mostra nel Finder") { store.revealOutputInFinder() }
                    .buttonStyle(.link)
            }
        } else if store.install != nil, !store.items.isEmpty {
            Text(plan)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var plan: String {
        let s = store.settings
        var parts: [String] = []
        parts.append(s.outputFormat == .keepOriginal ? "formato originale" : s.outputFormat.label)
        if s.outputFormat.supportsQuality || s.outputFormat == .keepOriginal {
            parts.append("qualità \(Int(s.quality))")
        }
        if s.resizeMode != .none { parts.append(s.resizeMode.label.lowercased()) }
        switch s.destination {
        case .sameFolder:
            parts.append("stessa cartella")
        case .subfolder:
            parts.append("cartella «\(s.subfolderName)»")
        case .customFolder:
            let name = s.customFolderURL?.lastPathComponent ?? "non impostata"
            parts.append("cartella «\(name)»")
        }
        return parts.joined(separator: " · ")
    }
}
