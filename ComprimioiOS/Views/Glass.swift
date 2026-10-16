//
//  Glass.swift
//  Comprimio iOS
//
//  Liquid Glass su iOS 26, materiali traslucidi prima. Stessi nomi del
//  LiquidGlass.swift del Mac, così le viste si leggono allo stesso modo.
//

import SwiftUI

extension View {
    /// Superficie vetro per barre e controlli flottanti.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 14) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }

    /// Sfondo per i pannelli di contenuto (i riquadri dell'anteprima).
    func contentPanel(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Color(uiColor: .secondarySystemBackground), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
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
