//
//  SettingsComponents.swift
//  Comprimio
//
//  Controlli riutilizzabili delle schede impostazioni.
//

import AppKit
import SwiftUI

/// Sezione di un `Form` con intestazione.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }
}

/// Etichetta + campo numerico sopra, slider sotto: come nella schermata di riferimento.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var suffix: String = ""
    var decimals: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                TextField("", value: $value, format: .number.precision(.fractionLength(decimals)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
            Slider(value: $value, in: range, step: step)
        }
        .padding(.vertical, 2)
    }
}

/// Campo intero con stepper.
struct IntField: View {
    let title: String
    @Binding var value: Int
    var suffix: String = ""
    var range: ClosedRange<Int> = 1...30000

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", value: $value, format: .number)
                    .frame(width: 66)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Stepper("", value: $value, in: range, step: 1)
                    .labelsHidden()
            }
        }
    }
}

struct HelpText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WarningText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}

/// Selettore di colore con campo esadecimale, per l'appiattimento della trasparenza.
struct HexColorField: View {
    @Binding var hex: String

    var body: some View {
        LabeledContent("Colore di sfondo") {
            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: hex) ?? .white) },
                    set: { hex = $0.hexString }
                ))
                .labelsHidden()

                TextField("#FFFFFF", text: $hex)
                    .frame(width: 84)
                    .monospaced()
            }
        }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(
            format: "#%02X%02X%02X",
            Int(round(rgb.redComponent * 255)),
            Int(round(rgb.greenComponent * 255)),
            Int(round(rgb.blueComponent * 255))
        )
    }
}
