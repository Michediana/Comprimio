//
//  PreviewZoom.swift
//  Comprimio
//
//  Zoom e panoramica condivisi dai due riquadri di anteprima: per
//  confrontare il risultato con l'originale le due immagini devono
//  restare inquadrate esattamente allo stesso modo.
//

import AppKit
import SwiftUI

struct PreviewZoom: Equatable {
    /// Fattore di ingrandimento: 1 = immagine adattata al riquadro.
    var scale: CGFloat = 1
    /// Spostamento in punti rispetto al centro, applicato dopo l'ingrandimento.
    var offset: CGSize = .zero

    /// Dimensione del riquadro e dell'immagine adattata: servono a limitare
    /// la panoramica ai bordi dell'immagine.
    private(set) var container: CGSize = .zero
    private(set) var content: CGSize = .zero
    /// Fattore al quale l'originale è mostrato a grandezza naturale (1:1).
    private(set) var nativeScale: CGFloat = 1

    var maxScale: CGFloat { max(24, nativeScale) }
    var isFit: Bool { scale <= 1.001 && offset == .zero }
    var isNative: Bool { abs(scale - nativeScale) < 0.01 }
    var canZoomOut: Bool { scale > 1.001 }
    var canZoomIn: Bool { scale < maxScale - 0.001 }

    mutating func reset() {
        scale = 1
        offset = .zero
    }

    /// Misure prese dal riquadro dell'originale, che fa da riferimento.
    mutating func measure(container: CGSize, content: CGSize, nativeScale: CGFloat) {
        self.container = container
        self.content = content
        self.nativeScale = max(1, nativeScale)
        scale = min(scale, maxScale)
        offset = clamped(offset)
    }

    /// Ingrandisce di `factor` lasciando fermo il punto `anchor`, espresso in
    /// punti rispetto al centro del riquadro.
    mutating func magnify(by factor: CGFloat, around anchor: CGPoint = .zero) {
        let target = min(max(scale * factor, 1), maxScale)
        guard target != scale else { return }
        let ratio = target / scale
        let moved = CGSize(
            width: anchor.x * (1 - ratio) + offset.width * ratio,
            height: anchor.y * (1 - ratio) + offset.height * ratio
        )
        scale = target
        offset = clamped(moved)
    }

    mutating func setScale(_ target: CGFloat) {
        guard scale > 0 else { return }
        magnify(by: target / scale)
    }

    mutating func pan(by delta: CGSize) {
        offset = clamped(CGSize(
            width: offset.width + delta.width,
            height: offset.height + delta.height
        ))
    }

    /// Evita di trascinare l'immagine oltre i bordi del riquadro.
    private func clamped(_ value: CGSize) -> CGSize {
        let limitX = max(0, (content.width * scale - container.width) / 2)
        let limitY = max(0, (content.height * scale - container.height) / 2)
        return CGSize(
            width: min(max(value.width, -limitX), limitX),
            height: min(max(value.height, -limitY), limitY)
        )
    }
}

/// Cattura pinch, ⌘-scroll, scroll e trascinamento sopra l'anteprima: su
/// macOS le gesture SwiftUI non ricevono gli eventi della rotella.
struct ZoomInteraction: NSViewRepresentable {
    var isZoomed: Bool
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onPan: (CGSize) -> Void
    var onDoubleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> ZoomInteractionView {
        let view = ZoomInteractionView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: ZoomInteractionView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: ZoomInteractionView) {
        view.onMagnify = onMagnify
        view.onPan = onPan
        view.onDoubleClick = onDoubleClick
        view.isZoomed = isZoomed
    }
}

final class ZoomInteractionView: NSView {
    var onMagnify: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onDoubleClick: ((CGPoint) -> Void)?

    var isZoomed = false {
        didSet {
            guard isZoomed != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    private var lastDragPoint: NSPoint?
    private var pushedCursor = false

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        if isZoomed { addCursorRect(bounds, cursor: .openHand) }
    }

    /// Punto dell'evento in punti rispetto al centro, con l'asse Y
    /// orientato come in SwiftUI (verso il basso).
    private func centered(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - bounds.midX, y: bounds.midY - point.y)
    }

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification, centered(event))
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘ + rotella ingrandisce, la rotella da sola sposta l'inquadratura.
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 120
                : event.scrollingDeltaY / 12
            onMagnify?(1 + delta, centered(event))
        } else {
            onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        }
    }

    override func mouseDown(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        if isZoomed {
            NSCursor.closedHand.push()
            pushedCursor = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastDragPoint = point }
        guard let last = lastDragPoint else { return }
        onPan?(CGSize(width: point.x - last.x, height: last.y - point.y))
    }

    override func mouseUp(with event: NSEvent) {
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        lastDragPoint = nil
        if event.clickCount == 2 { onDoubleClick?(centered(event)) }
    }
}
