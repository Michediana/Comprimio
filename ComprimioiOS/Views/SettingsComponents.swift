//
//  SettingsComponents.swift
//  Comprimio iOS
//
//  Controlli delle impostazioni. Gli stessi del Mac, con i controlli di
//  UIKit/SwiftUI al posto di quelli disegnati su misura in AppKit:
//  `TickedSlider` invece di `TickSlider`, `TextField` invece di
//  `NativeTextField`.
//

import SwiftUI
import UIKit

/// Sezione di un `Form` con intestazione.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            Text(title)
        }
    }
}

// MARK: - Campi di testo

/// Campo di testo libero (nome cartella, prefisso, colore esadecimale…).
struct TextBox: View {
    @Binding var text: String
    var placeholder: String = ""
    var width: CGFloat
    var monospaced: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(monospaced ? .body.monospaced() : .body)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .frame(width: width)
    }
}

/// Campo numerico: mostra sempre il valore formattato e lo riporta
/// nell'intervallo consentito quando si conferma o si esce dal campo.
struct NumberBox: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var decimals: Int = 0
    var width: CGFloat

    @State private var text = ""
    @FocusState private var focused: Bool

    private var formatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f
    }

    private var display: String {
        formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .keyboardType(decimals > 0 ? .decimalPad : .numberPad)
            .frame(width: width)
            .focused($focused)
            .onAppear { text = display }
            .onSubmit(commit)
            // Il tastierino numerico non ha Invio: si conferma uscendo.
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            // Non sovrascrivere quello che l'utente sta digitando.
            .onChange(of: value) { _, _ in
                if !focused { text = display }
            }
    }

    private func commit() {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        if let parsed = Double(cleaned) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        text = display
    }
}

// MARK: - Slider con tacche

/// Slider con tacche su valori «tondi» e il numero sotto ognuna. Le tacche
/// seguono la corsa del cursore misurata su `UISlider`, così restano
/// allineate qualunque sia lo stile di sistema.
struct TickedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 1) {
            Slider(value: $value, in: range, step: step)
            GeometryReader { geo in
                let ticks = Self.tickValues(range: range, step: step)
                let labelled = Self.labelled(ticks, width: geo.size.width, range: range)
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { tick in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.5))
                            .frame(width: 1, height: 4)
                            .position(x: x(of: tick, width: geo.size.width), y: 2)
                    }
                    ForEach(labelled, id: \.self) { tick in
                        Text(Self.label(for: tick))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .position(x: x(of: tick, width: geo.size.width), y: 11)
                    }
                }
            }
            .frame(height: 17)
            .opacity(isEnabled ? 1 : 0.4)
            .accessibilityHidden(true)
        }
    }

    private func x(of tick: Double, width: CGFloat) -> CGFloat {
        let inset = Self.thumbInset
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return inset }
        return inset + CGFloat((tick - range.lowerBound) / span) * max(0, width - inset * 2)
    }

    /// Distanza fra il bordo dello slider e il centro del cursore a fine
    /// corsa, chiesta a `UISlider` una volta sola.
    @MainActor private static let thumbInset: CGFloat = {
        let slider = UISlider(frame: CGRect(x: 0, y: 0, width: 300, height: 44))
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: slider.minimumValue)
        return thumb.width > 0 ? thumb.midX : 14
    }()

    /// Le etichette che ci stanno: sempre i due estremi, poi quelle
    /// intermedie distanti almeno 30 punti dalle altre.
    private static func labelled(_ ticks: [Double], width: CGFloat, range: ClosedRange<Double>) -> [Double] {
        guard ticks.count > 2 else { return ticks }
        let span = range.upperBound - range.lowerBound
        let usable = max(1, width - thumbInset * 2)
        let spacing = usable * CGFloat((ticks[1] - ticks[0]) / span)
        let every = max(1, Int((30 / max(spacing, 1)).rounded(.up)))
        var result = [ticks[0]]
        for index in stride(from: every, to: ticks.count - 1, by: every) {
            let distanceToEnd = usable * CGFloat((ticks[ticks.count - 1] - ticks[index]) / span)
            if distanceToEnd >= 30 { result.append(ticks[index]) }
        }
        result.append(ticks[ticks.count - 1])
        return result
    }

    /// Valori da etichettare: passo «tondo» (1, 2, 5, 25, 50…) compatibile
    /// con lo step, più i due estremi. La stessa regola del Mac.
    static func tickValues(range: ClosedRange<Double>, step: Double) -> [Double] {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return [] }

        let candidates: [Double] = [0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000]
        let interval = candidates.first {
            $0 >= span / 8 - 1e-9 && (step <= 0 || isMultiple($0, of: step))
        } ?? span

        var values = [range.lowerBound]
        var value = (range.lowerBound / interval).rounded(.up) * interval
        while value < range.upperBound - interval / 4 {
            if value > range.lowerBound + interval / 4 { values.append(value) }
            value += interval
        }
        values.append(range.upperBound)
        return values
    }

    private static func isMultiple(_ value: Double, of step: Double) -> Bool {
        let ratio = value / step
        return abs(ratio - ratio.rounded()) < 1e-6 && ratio >= 1 - 1e-6
    }

    private static func label(for value: Double) -> String {
        abs(value - value.rounded()) < 1e-9
            ? String(Int(value.rounded()))
            : String(format: "%.1f", locale: .current, value)
    }
}

/// Etichetta, campo numerico e stepper sopra, slider sotto: come sul Mac.
struct ValueSlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var suffix: String = ""
    var decimals: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                NumberBox(value: $value, range: range, decimals: decimals, width: 64)
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary)
                }
            }
            TickedSlider(value: $value, range: range, step: step)
        }
        .padding(.vertical, 2)
    }
}

/// Campo intero con stepper.
struct IntField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    var suffix: String = ""
    var range: ClosedRange<Int> = 1...30000

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                NumberBox(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0.rounded()) }
                    ),
                    range: Double(range.lowerBound)...Double(range.upperBound),
                    width: 76
                )
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Stepper(value: $value, in: range, step: 1) { EmptyView() }
                    .labelsHidden()
            }
        }
    }
}

struct HelpText: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    /// Testo già tradotto altrove (un suggerimento scelto a runtime).
    init(verbatim text: String) { self.text = Text(text) }

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WarningText: View {
    private let text: Text

    init(_ key: LocalizedStringKey) { self.text = Text(key) }
    /// Testo già tradotto altrove (il motivo per cui la filigrana non si applica).
    init(verbatim text: String) { self.text = Text(text) }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}

/// Griglia 3×3 per l'ancora della filigrana, a misura di dito.
struct PositionGrid: View {
    @Binding var selection: WatermarkPosition

    private let rows: [[WatermarkPosition]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight]
    ]

    var body: some View {
        LabeledContent("Position") {
            VStack(spacing: 4) {
                ForEach(rows.indices, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(rows[row]) { position in
                            let selected = position == selection
                            Button {
                                selection = position
                            } label: {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(selected ? Color.accentColor : Color.secondary.opacity(0.2))
                                    .frame(width: 34, height: 24)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(position.label)
                            .accessibilityAddTraits(selected ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }
}

/// Selettore di colore con campo esadecimale.
struct HexColorField: View {
    var title: LocalizedStringKey = "Background color"
    @Binding var hex: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ColorPicker(selection: Binding(
                    get: { Color(uiColor: UIColor(hex: hex) ?? .white) },
                    set: { hex = $0.hexString }
                ), supportsOpacity: false) { EmptyView() }
                .labelsHidden()

                TextBox(text: $hex, placeholder: "#FFFFFF", width: 100, monospaced: true)
            }
        }
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((number >> 16) & 0xFF) / 255,
            green: CGFloat((number >> 8) & 0xFF) / 255,
            blue: CGFloat(number & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#FFFFFF" }
        func byte(_ component: CGFloat) -> Int { Int(round(min(max(component, 0), 1) * 255)) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
