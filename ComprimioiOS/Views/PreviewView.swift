//
//  PreviewView.swift
//  Comprimio iOS
//
//  Originale e risultato affiancati, con lo stesso zoom: `PreviewZoom` è
//  quello del Mac, condiviso. Sul Mac pinch, rotella e trascinamento arrivano
//  da una NSView; qui da `MagnifyGesture` e `DragGesture`, su entrambi i
//  riquadri, che muovono la stessa inquadratura.
//

import SwiftUI

struct PreviewView: View {
    @EnvironmentObject private var store: AppStore

    /// Zoom unico per i due riquadri: l'inquadratura deve restare la stessa
    /// da entrambe le parti, altrimenti il confronto non dice nulla.
    @State private var zoom = PreviewZoom()

    var body: some View {
        GeometryReader { geo in
            // In verticale i riquadri si impilano: affiancati sarebbero due
            // strisce sottili.
            let layout = geo.size.width >= geo.size.height * 0.9
                ? AnyLayout(HStackLayout(spacing: 12))
                : AnyLayout(VStackLayout(spacing: 12))
            layout {
                PreviewTile(
                    title: "Original",
                    image: store.previewOriginal,
                    detail: originalDetail,
                    isLoading: false,
                    message: store.items.isEmpty ? String(localized: "Add an image to see the preview.") : nil,
                    zoom: $zoom,
                    isReference: true,
                    pixelSize: store.selectedItem?.pixelSize,
                    accessory: { EmptyView() }
                )

                PreviewTile(
                    title: "Result",
                    image: store.previewResult,
                    detail: resultDetail,
                    isLoading: store.isRenderingPreview,
                    message: store.previewError,
                    zoom: $zoom,
                    accessory: { savingBadge }
                )
            }
        }
        .overlay(alignment: .topTrailing) {
            if store.previewOriginal != nil { zoomBar }
        }
        .padding(16)
        // Cambiando file l'inquadratura precedente non ha più senso.
        .onChange(of: store.selectedItem?.id) { _, _ in zoom.reset() }
        // Ingrandendo servono i pixel veri: l'anteprima ridotta a 1600 px
        // non permetterebbe di confrontare gli artefatti di compressione.
        .onChange(of: zoom.scale > 1.01) { _, zoomed in
            if zoomed { store.enablePreviewDetail() }
        }
    }

    private var originalDetail: String {
        guard let item = store.selectedItem else { return " " }
        return "\(Fmt.pixels(item.pixelSize)) · \(Fmt.bytes(item.originalSize)) · \(item.formatName)"
    }

    private var resultDetail: String {
        guard store.selectedItem != nil else { return " " }
        guard let size = store.previewResultSize else { return " " }
        let format = store.selectedItem.map { store.settings.targetFormat(for: $0.url).label } ?? ""
        var text = "\(Fmt.pixels(store.previewPixelSize)) · \(Fmt.bytes(size)) · \(format)"
        if store.previewIsDownscaled {
            text += " · " + String(localized: "estimated on a downscaled preview")
        }
        return text
    }

    @ViewBuilder
    private var savingBadge: some View {
        if let item = store.selectedItem,
           let size = store.previewResultSize,
           item.originalSize > 0,
           !store.previewIsDownscaled {
            let saving = 1 - Double(size) / Double(item.originalSize)
            Text(Fmt.percent(saving))
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill((saving >= 0 ? Color.green : Color.orange).opacity(0.18))
                )
                .foregroundStyle(saving >= 0 ? Color.green : Color.orange)
        }
    }

    // MARK: - Controlli di zoom

    private var zoomBar: some View {
        HStack(spacing: 12) {
            Button { zoom.magnify(by: 1 / 1.6) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(!zoom.canZoomOut)
            .keyboardShortcut("-", modifiers: .command)
            .accessibilityLabel("Zoom out")

            Text(String(format: "%.1f×", locale: .current, zoom.scale))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38)

            Button { zoom.magnify(by: 1.6) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!zoom.canZoomIn)
            .keyboardShortcut("+", modifiers: .command)
            .accessibilityLabel("Zoom in")

            Divider().frame(height: 14)

            // «1:1» è uguale in tutte le lingue: fuori dal catalogo.
            Button { zoom.setScale(zoom.nativeScale) } label: { Text(verbatim: "1:1") }
                .disabled(zoom.isNative)
                .accessibilityLabel("Actual pixels of the original")

            Button("Fit") { zoom.reset() }
                .disabled(zoom.isFit)
                .keyboardShortcut("0", modifiers: .command)
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: 12)
        // Sopra il titolo del riquadro di destra, non sopra l'immagine.
        .padding(.trailing, 16)
        .padding(.top, 6)
    }
}

struct PreviewTile<Accessory: View>: View {
    let title: LocalizedStringKey
    let image: CGImage?
    let detail: String
    let isLoading: Bool
    var message: String?
    @Binding var zoom: PreviewZoom
    /// Solo un riquadro misura l'inquadratura: quello dell'originale.
    var isReference: Bool
    /// Pixel reali dell'originale, per il fattore 1:1.
    var pixelSize: CGSize?
    @ViewBuilder var accessory: Accessory

    /// Margine interno del riquadro attorno all'immagine.
    private let inset: CGFloat = 6

    /// Valori della gesture al passo precedente: le gesture riportano il
    /// totale dall'inizio, lo zoom vuole l'incremento.
    @State private var lastMagnification: CGFloat = 1
    @State private var lastTranslation: CGSize = .zero

    init(
        title: LocalizedStringKey,
        image: CGImage?,
        detail: String,
        isLoading: Bool,
        message: String? = nil,
        zoom: Binding<PreviewZoom>,
        isReference: Bool = false,
        pixelSize: CGSize? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.image = image
        self.detail = detail
        self.isLoading = isLoading
        self.message = message
        self._zoom = zoom
        self.isReference = isReference
        self.pixelSize = pixelSize
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                accessory
                Spacer(minLength: 0)
            }
            .frame(minHeight: 30)

            GeometryReader { geo in
                ZStack {
                    CheckerboardBackground()

                    if let image {
                        imageLayer(image, in: geo.size)
                    } else if let message, !isLoading {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(16)
                    }

                    if isLoading { RenderingIndicator() }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
                .gesture(image == nil ? nil : gestures(in: geo.size))
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentPanel(cornerRadius: 10)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// Pizzico per ingrandire attorno alle dita, trascinamento per spostare,
    /// doppio tocco per alternare adattato e 2×.
    private func gestures(in size: CGSize) -> some Gesture {
        let magnify = MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                zoom.magnify(by: factor, around: centered(value.startLocation, in: size))
            }
            .onEnded { _ in lastMagnification = 1 }

        let pan = DragGesture(minimumDistance: 2)
            .onChanged { value in
                zoom.pan(by: CGSize(
                    width: value.translation.width - lastTranslation.width,
                    height: value.translation.height - lastTranslation.height
                ))
                lastTranslation = value.translation
            }
            .onEnded { _ in lastTranslation = .zero }

        let doubleTap = SpatialTapGesture(count: 2)
            .onEnded { value in
                if zoom.isFit {
                    zoom.magnify(by: 2, around: centered(value.location, in: size))
                } else {
                    zoom.reset()
                }
            }

        return doubleTap.exclusively(before: magnify.simultaneously(with: pan))
    }

    /// Punto in coordinate rispetto al centro del riquadro, come lo vuole
    /// `PreviewZoom.magnify(by:around:)`.
    private func centered(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
    }

    /// L'immagine è ingrandita cambiandone il riquadro, non con `scaleEffect`:
    /// così viene ridisegnata dalla sorgente e lo zoom mostra dettaglio vero.
    @ViewBuilder
    private func imageLayer(_ image: CGImage, in container: CGSize) -> some View {
        let box = CGSize(
            width: max(0, container.width - inset * 2),
            height: max(0, container.height - inset * 2)
        )
        let fit = Self.fitSize(of: image, in: box)
        let native = nativeScale(of: image, fit: fit)
        let metrics = PreviewMetrics(container: box, content: fit, native: native)

        Image(decorative: image, scale: 1)
            .resizable()
            // Oltre la risoluzione nativa mostro i pixel senza sfumarli:
            // è l'unico modo per vedere davvero gli artefatti.
            .interpolation(zoom.scale >= native ? .none : .medium)
            .frame(width: fit.width * zoom.scale, height: fit.height * zoom.scale)
            .offset(zoom.offset)
            // L'immagine precedente resta visibile ma attenuata
            // mentre ImageMagick prepara la nuova.
            .opacity(isLoading ? 0.3 : 1)
            .animation(.easeInOut(duration: 0.15), value: isLoading)
            .onAppear { apply(metrics) }
            .onChange(of: metrics) { _, newValue in apply(newValue) }
    }

    private func apply(_ metrics: PreviewMetrics) {
        guard isReference else { return }
        zoom.measure(
            container: metrics.container,
            content: metrics.content,
            nativeScale: metrics.native
        )
    }

    /// Fattore di zoom che mostra l'originale con un pixel per punto, come
    /// «1:1» sul Mac.
    private func nativeScale(of image: CGImage, fit: CGSize) -> CGFloat {
        let pixels = pixelSize ?? CGSize(width: image.width, height: image.height)
        guard fit.width > 0, pixels.width > 0 else { return 1 }
        return max(1, pixels.width / fit.width)
    }

    /// Dimensione dell'immagine adattata al riquadro, mantenendo le proporzioni.
    private static func fitSize(of image: CGImage, in box: CGSize) -> CGSize {
        let size = CGSize(width: image.width, height: image.height)
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let factor = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }
}

/// Misure del riquadro, raccolte in un valore per un solo `onChange`.
struct PreviewMetrics: Equatable {
    let container: CGSize
    let content: CGSize
    let native: CGFloat
}

/// Indicatore mostrato al centro del riquadro mentre ImageMagick lavora.
struct RenderingIndicator: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Rendering preview…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassSurface(cornerRadius: 12)
        .transition(.opacity)
    }
}

/// Scacchiera chiara per rendere visibile la trasparenza.
struct CheckerboardBackground: View {
    private let cell: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            let base = Color(uiColor: .systemBackground)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(base))
            let columns = Int(size.width / cell) + 1
            let rows = Int(size.height / cell) + 1
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(
                        x: CGFloat(column) * cell,
                        y: CGFloat(row) * cell,
                        width: cell,
                        height: cell
                    )
                    context.fill(Path(rect), with: .color(.gray.opacity(0.12)))
                }
            }
        }
    }
}
