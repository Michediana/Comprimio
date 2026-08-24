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

// MARK: - Campo di testo

/// Campo di testo nativo con cornice sempre visibile: dentro un `Form`
/// raggruppato SwiftUI toglie il bordo e il campo sembra un'etichetta, mentre
/// la versione «finta» in SwiftUI mandava a capo placeholder e valore.
private struct NativeTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var alignment: NSTextAlignment
    var monospaced: Bool
    /// `true` = aggiorna a ogni tasto, `false` = solo a Invio o quando esce il fuoco.
    var updatesWhileTyping: Bool
    var onCommit: (String) -> String

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.alignment = alignment
        field.font = monospaced
            ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.systemFontSize)
        field.isEnabled = isEnabled
        // Non sovrascrivere quello che l'utente sta digitando.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField

        init(_ parent: NativeTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard parent.updatesWhileTyping,
                  let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            commit(field)
        }

        @objc func commit(_ sender: NSTextField) {
            let normalized = parent.onCommit(sender.stringValue)
            if sender.stringValue != normalized { sender.stringValue = normalized }
            if parent.text != normalized { parent.text = normalized }
        }
    }
}

/// Campo di testo libero (nome cartella, prefisso, colore esadecimale…).
struct TextBox: View {
    @Binding var text: String
    var placeholder: String = ""
    var width: CGFloat
    var alignment: NSTextAlignment = .left
    var monospaced: Bool = false

    var body: some View {
        NativeTextField(
            text: $text,
            placeholder: placeholder,
            alignment: alignment,
            monospaced: monospaced,
            updatesWhileTyping: true,
            onCommit: { $0 }
        )
        .frame(width: width, height: 22)
    }
}

/// Campo numerico: mostra sempre il valore formattato e lo riporta nell'intervallo
/// consentito quando si conferma con Invio o si esce dal campo.
struct NumberBox: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var decimals: Int = 0
    var width: CGFloat

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
        NativeTextField(
            text: Binding(get: { display }, set: { _ in }),
            placeholder: "",
            alignment: .right,
            monospaced: true,
            updatesWhileTyping: false,
            onCommit: { typed in
                guard let parsed = parse(typed) else { return display }
                let clamped = min(max(parsed, range.lowerBound), range.upperBound)
                value = clamped
                return formatter.string(from: NSNumber(value: clamped)) ?? display
            }
        )
        .frame(width: width, height: 22)
    }

    private func parse(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }
}

// MARK: - Slider con tacche

/// Slider con tacche su valori "tondi" e il numero corrispondente sotto ognuna.
/// Le tacche automatiche di `NSSlider` sono equidistanti fra minimo e massimo,
/// quindi cadrebbero su valori come 1‑12‑23: impossibili da etichettare.
struct TickSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TickSliderView {
        let view = TickSliderView()
        view.slider.target = context.coordinator
        view.slider.action = #selector(Coordinator.sliderChanged(_:))
        return view
    }

    func updateNSView(_ view: TickSliderView, context: Context) {
        context.coordinator.parent = self
        let slider = view.slider
        if slider.minValue != range.lowerBound || slider.maxValue != range.upperBound {
            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
            view.ticks = TickSliderView.tickValues(range: range, step: step)
        } else if view.ticks.isEmpty {
            view.ticks = TickSliderView.tickValues(range: range, step: step)
        }
        if slider.doubleValue != value { slider.doubleValue = value }
        if slider.isEnabled != isEnabled {
            slider.isEnabled = isEnabled
            view.needsDisplay = true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TickSliderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: TickSlider

        init(_ parent: TickSlider) { self.parent = parent }

        @objc func sliderChanged(_ sender: NSSlider) {
            let step = parent.step
            let range = parent.range
            var newValue = sender.doubleValue
            if step > 0 {
                newValue = range.lowerBound + ((newValue - range.lowerBound) / step).rounded() * step
            }
            newValue = min(max(newValue, range.lowerBound), range.upperBound)
            if sender.doubleValue != newValue { sender.doubleValue = newValue }
            if parent.value != newValue { parent.value = newValue }
        }
    }
}

/// Slider nativo con, sotto, tacche ed etichette disegnate su misura.
final class TickSliderView: NSView {
    let slider = NSSlider()
    var ticks: [Double] = [] { didSet { needsDisplay = true } }

    private let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
    private let tickLength: CGFloat = 4
    private let gapAboveTicks: CGFloat = 1
    private let gapBelowTicks: CGFloat = 2
    /// Centro del cursore ai due estremi della corsa, in coordinate della vista.
    private var track: (start: CGFloat, end: CGFloat)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        slider.isContinuous = true
        slider.sliderType = .linear
        slider.numberOfTickMarks = 0
        addSubview(slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    private var sliderHeight: CGFloat { max(slider.intrinsicContentSize.height, 20) }

    private var labelHeight: CGFloat { ceil(labelFont.ascender - labelFont.descender) }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: sliderHeight + gapAboveTicks + tickLength + gapBelowTicks + labelHeight
        )
    }

    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: bounds.height - sliderHeight, width: bounds.width, height: sliderHeight)
        track = measureTrack()
        needsDisplay = true
    }

    /// Chiede alla cella dove finirebbe il cursore agli estremi: così le tacche
    /// restano allineate al cursore qualunque sia lo stile di slider di sistema.
    private func measureTrack() -> (CGFloat, CGFloat)? {
        guard let cell = slider.cell as? NSSliderCell, slider.maxValue > slider.minValue else { return nil }
        let saved = cell.doubleValue
        cell.doubleValue = slider.minValue
        let start = cell.knobRect(flipped: slider.isFlipped).midX
        cell.doubleValue = slider.maxValue
        let end = cell.knobRect(flipped: slider.isFlipped).midX
        cell.doubleValue = saved
        return end > start ? (start, end) : nil
    }

    private func position(of value: Double) -> CGFloat? {
        guard let track, slider.maxValue > slider.minValue else { return nil }
        let fraction = (value - slider.minValue) / (slider.maxValue - slider.minValue)
        return track.start + CGFloat(fraction) * (track.end - track.start)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !ticks.isEmpty else { return }
        let dimmed = !slider.isEnabled
        let tickColor = NSColor.tertiaryLabelColor.withAlphaComponent(dimmed ? 0.25 : 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(dimmed ? 0.4 : 1)
        ]

        let tickTop = bounds.height - sliderHeight - gapAboveTicks
        let labelTop = tickTop - tickLength - gapBelowTicks

        // Le etichette hanno la precedenza agli estremi: se lo spazio non basta
        // si saltano quelle intermedie, mai i due limiti dell'intervallo.
        var order = Array(ticks.indices)
        if let last = order.last, order.count > 1 { order = [order[0], last] + order.dropFirst().dropLast() }
        var occupied: [ClosedRange<CGFloat>] = []

        tickColor.setFill()
        for value in ticks {
            guard let x = position(of: value) else { continue }
            NSRect(x: (x - 0.5).rounded(), y: tickTop - tickLength, width: 1, height: tickLength).fill()
        }

        for index in order {
            guard let x = position(of: ticks[index]) else { continue }
            let text = Self.label(for: ticks[index]) as NSString
            let size = text.size(withAttributes: attributes)
            var originX = x - size.width / 2
            originX = min(max(originX, 0), max(0, bounds.width - size.width))
            let span = (originX - 3)...(originX + size.width + 3)
            guard !occupied.contains(where: { $0.overlaps(span) }) else { continue }
            occupied.append(span)
            text.draw(at: NSPoint(x: originX, y: labelTop - size.height), withAttributes: attributes)
        }
    }

    /// Valori da etichettare: passo "tondo" (1, 2, 5, 25, 50…) compatibile con lo
    /// step dello slider, più sempre i due estremi dell'intervallo.
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
            : String(format: "%.1f", value)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                NumberBox(value: $value, range: range, decimals: decimals, width: 60)
                if !suffix.isEmpty {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
            }
            TickSlider(value: $value, range: range, step: step)
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
                NumberBox(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Int($0.rounded()) }
                    ),
                    range: Double(range.lowerBound)...Double(range.upperBound),
                    width: 70
                )
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

                TextBox(
                    text: $hex,
                    placeholder: "#FFFFFF",
                    width: 90,
                    alignment: .center,
                    monospaced: true
                )
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
