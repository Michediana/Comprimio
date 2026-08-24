//
//  LiquidGlass.swift
//  Comprimio
//
//  Liquid Glass su macOS 26+, con fallback ai materiali traslucidi
//  fino a macOS 13.
//

import SwiftUI

extension View {
    /// Superficie vetro per barre e controlli flottanti.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 14, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    /// Sfondo per i pannelli di contenuto (lista, anteprima, impostazioni).
    func contentPanel(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

/// Contenitore che fonde gli elementi vetro vicini (solo macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
