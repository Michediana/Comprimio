//
//  PreviewPane.swift
//  Comprimio
//

import AppKit
import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject private var store: AppStore

    /// Zoom unico per i due riquadri: l'inquadratura deve restare la stessa
    /// da entrambe le parti, altrimenti il confronto non dice nulla.
    @State private var zoom = PreviewZoom()

    var body: some View {
        HStack(spacing: 12) {
            PreviewTile(
                title: "Originale",
                image: store.previewOriginal,
                detail: originalDetail,
                isLoading: false,
                message: store.items.isEmpty ? "Aggiungi un'immagine per vedere l'anteprima." : nil,
                zoom: $zoom,
                isReference: true,
                pixelSize: store.selectedItem?.pixelSize,
                accessory: { EmptyView() }
            )

            PreviewTile(
                title: "Risultato",
                image: store.previewResult,
                detail: resultDetail,
                isLoading: store.isRenderingPreview,
                message: store.previewError,
                zoom: $zoom,
                accessory: { savingBadge }
            )
        }
        .overlay(alignment: .topTrailing) {
            if store.previewOriginal != nil { zoomBar }
        }
        .padding(12)
        // Cambiando file l'inquadratura precedente non ha più senso.
        .onChange(of: store.selectedItem?.id) { _ in zoom.reset() }
        // Ingrandendo servono i pixel veri: l'anteprima ridotta a 1600 px
        // non permetterebbe di confrontare gli artefatti di compressione.
        .onChange(of: zoom.scale > 1.01) { zoomed in
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
            text += " · stima su anteprima ridotta"
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
        HStack(spacing: 5) {
            Button { zoom.magnify(by: 1 / 1.6) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(!zoom.canZoomOut)
            .keyboardShortcut("-", modifiers: .command)
            .help("Riduci")

            Text(String(format: "%.1f×", zoom.scale))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34)

            Button { zoom.magnify(by: 1.6) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(!zoom.canZoomIn)
            .keyboardShortcut("+", modifiers: .command)
            .help("Ingrandisci")

            Divider().frame(height: 12)

            Button("1:1") { zoom.setScale(zoom.nativeScale) }
                .disabled(zoom.isNative)
                .help("Pixel reali dell'originale")

            Button("Adatta") { zoom.reset() }
                .disabled(zoom.isFit)
                .keyboardShortcut("0", modifiers: .command)
                .help("Adatta l'immagine al riquadro")
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassSurface(cornerRadius: 9)
        .help("Pizzica, ⌘ + rotella o doppio clic per ingrandire; trascina per spostare")
    }
}

struct PreviewTile<Accessory: View>: View {
    let title: String
    let image: NSImage?
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

    init(
        title: String,
        image: NSImage?,
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

                    if image != nil {
                        ZoomInteraction(
                            isZoomed: zoom.scale > 1.001,
                            onMagnify: { factor, anchor in zoom.magnify(by: factor, around: anchor) },
                            onPan: { zoom.pan(by: $0) },
                            onDoubleClick: { anchor in
                                if zoom.isFit {
                                    zoom.magnify(by: 2, around: anchor)
                                } else {
                                    zoom.reset()
                                }
                            }
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentPanel(cornerRadius: 10)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// L'immagine è ingrandita cambiandone il riquadro, non con `scaleEffect`:
    /// così viene ridisegnata dalla sorgente e lo zoom mostra dettaglio vero.
    @ViewBuilder
    private func imageLayer(_ image: NSImage, in container: CGSize) -> some View {
        let box = CGSize(
            width: max(0, container.width - inset * 2),
            height: max(0, container.height - inset * 2)
        )
        let fit = Self.fitSize(of: image, in: box)
        let native = nativeScale(of: image, fit: fit)
        let metrics = PreviewMetrics(container: box, content: fit, native: native)

        Image(nsImage: image)
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
            .onChange(of: metrics) { apply($0) }
    }

    private func apply(_ metrics: PreviewMetrics) {
        guard isReference else { return }
        zoom.measure(
            container: metrics.container,
            content: metrics.content,
            nativeScale: metrics.native
        )
    }

    /// Fattore di zoom che mostra l'originale a grandezza naturale.
    private func nativeScale(of image: NSImage, fit: CGSize) -> CGFloat {
        let pixels = pixelSize ?? image.size
        guard fit.width > 0, pixels.width > 0 else { return 1 }
        return max(1, pixels.width / fit.width)
    }

    /// Dimensione dell'immagine adattata al riquadro, mantenendo le proporzioni.
    private static func fitSize(of image: NSImage, in box: CGSize) -> CGSize {
        let size = image.size
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
                .progressViewStyle(.circular)
                .controlSize(.small)
            Text("Anteprima in corso…")
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
    private let cell: CGFloat = 9

    var body: some View {
        Canvas { context, size in
            let base = Color(nsColor: .textBackgroundColor)
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
