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
        // Altezza fissa: le due barre sono più alte della riga di testo che
        // mostrano a riposo, e senza questo la barra sobbalza a ogni avvio.
        .frame(minHeight: 34)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var status: some View {
        if store.isProcessing {
            progressBars
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

    /// Due barre: sopra l'immagine su cui `magick` sta lavorando, sotto il
    /// batch. La prima misura la fase in corso (caricamento, ridimensionamento,
    /// scrittura), perché è l'unico avanzamento che ImageMagick sa riportare.
    @ViewBuilder
    private var progressBars: some View {
        VStack(alignment: .leading, spacing: 3) {
            bar(
                value: store.focusedItem?.progress.fraction,
                leading: itemCaption,
                trailing: store.focusedItem.map { "\(Int($0.progress.fraction * 100))%" }
            )
            bar(
                value: store.batchProgress,
                leading: "Batch",
                trailing: "\(store.processedCount)/\(store.items.count)"
            )
        }
        .frame(maxWidth: 340)
    }

    /// `value` nullo: la corsia è appena partita e `magick` non ha ancora
    /// riportato nulla, quindi la barra si muove senza indicare una frazione.
    @ViewBuilder
    private func bar(value: Double?, leading: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Text(leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)

            Group {
                if let value {
                    ProgressView(value: min(max(value, 0), 1))
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 110)

            Text(trailing ?? "")
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Nome del file in lavorazione con la fase, più le corsie in parallelo.
    private var itemCaption: String {
        guard let focused = store.focusedItem else { return "Avvio…" }
        var caption = "\(focused.progress.phase) \(focused.item.name)"
        let others = store.activeCount - 1
        if others > 0 { caption += " · +\(others)" }
        return caption
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
