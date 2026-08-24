//
//  PreviewPane.swift
//  Comprimio
//

import AppKit
import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            PreviewTile(
                title: "Originale",
                image: store.previewOriginal,
                detail: originalDetail,
                isLoading: false,
                message: store.items.isEmpty ? "Aggiungi un'immagine per vedere l'anteprima." : nil,
                accessory: { EmptyView() }
            )

            PreviewTile(
                title: "Risultato",
                image: store.previewResult,
                detail: resultDetail,
                isLoading: store.isRenderingPreview,
                message: store.previewError,
                accessory: { savingBadge }
            )
        }
        .padding(12)
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
}

struct PreviewTile<Accessory: View>: View {
    let title: String
    let image: NSImage?
    let detail: String
    let isLoading: Bool
    var message: String?
    @ViewBuilder var accessory: Accessory

    init(
        title: String,
        image: NSImage?,
        detail: String,
        isLoading: Bool,
        message: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.image = image
        self.detail = detail
        self.isLoading = isLoading
        self.message = message
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.semibold))
                accessory
                Spacer(minLength: 0)
            }

            ZStack {
                CheckerboardBackground()

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                        // L'immagine precedente resta visibile ma attenuata
                        // mentre ImageMagick prepara la nuova.
                        .opacity(isLoading ? 0.3 : 1)
                        .animation(.easeInOut(duration: 0.15), value: isLoading)
                } else if let message, !isLoading {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                }

                if isLoading { RenderingIndicator() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentPanel(cornerRadius: 10)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
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
