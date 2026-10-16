//
//  FileListView.swift
//  Comprimio iOS
//
//  La lista nella sidebar dell'iPad: miniatura, nome, dimensioni, esito.
//  Sul Mac è una tabella a colonne; qui le stesse informazioni stanno in due
//  righe per elemento.
//

import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isDropTargeted = false

    var body: some View {
        List(selection: $store.selection) {
            ForEach(store.items) { item in
                FileRow(item: item)
                    .tag(item.id)
                    .contextMenu { menu(for: item) }
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { store.items[$0].id })
                store.remove(ids)
            }
            .deleteDisabled(store.isProcessing)
        }
        .listStyle(.sidebar)
        .overlay {
            if store.items.isEmpty { EmptyListPlaceholder() }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.folder, .image], isTargeted: $isDropTargeted) { providers in
            store.handleDrop(providers)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.items.isEmpty { footer }
        }
    }

    @ViewBuilder
    private func menu(for item: ImageItem) -> some View {
        let ids = store.selection.contains(item.id) ? store.selection : [item.id]
        if let output = item.outputURL {
            ShareLink(item: output) {
                Label("Share Result", systemImage: "square.and.arrow.up")
            }
        }
        Button(role: .destructive) {
            store.remove(ids)
        } label: {
            Label("Remove from List", systemImage: "minus.circle")
        }
        .disabled(store.isProcessing)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(store.items.count) images")
            if store.totalOriginalSize > 0 {
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(Fmt.bytes(store.totalOriginalSize))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .font(.footnote)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct FileRow: View {
    let item: ImageItem

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(url: item.url)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(Fmt.bytes(item.originalSize))
                    if let output = item.outputSize {
                        Image(systemName: "arrow.right")
                            .imageScale(.small)
                        Text(Fmt.bytes(output))
                        SavingLabel(saving: item.saving)
                    } else {
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(Fmt.pixels(item.pixelSize))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
            StatusIcon(status: item.status)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

struct SavingLabel: View {
    let saving: Double?

    var body: some View {
        if let saving {
            Text(Fmt.percent(saving))
                .foregroundStyle(saving >= 0 ? Color.green : Color.orange)
        }
    }
}

private struct StatusIcon: View {
    let status: ProcessingStatus

    var body: some View {
        Group {
            if status == .processing {
                ProgressView()
            } else if status != .pending {
                Image(systemName: status.symbol)
                    .foregroundStyle(status == .done ? Color.green : Color.red)
            }
        }
        .accessibilityLabel(status.label)
    }
}

private struct EmptyListPlaceholder: View {
    var body: some View {
        ContentUnavailableView {
            Label("No images", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Add photos or files with the + button, or drag them here.")
        }
    }
}

// MARK: - Miniature

/// Miniatura di QuickLook, generata una volta per file e tenuta in memoria:
/// la lista si ridisegna a ogni aggiornamento di avanzamento.
struct Thumbnail: View {
    let url: URL

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            image = await ThumbnailCache.shared.thumbnail(for: url, side: 44, scale: displayScale)
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSURL, UIImage>()

    init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL, side: CGFloat, scale: CGFloat) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: scale,
            representationTypes: .thumbnail
        )
        // Formati che QuickLook non conosce (PCX, XCF…): resta il segnaposto.
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        else { return nil }
        cache.setObject(representation.uiImage, forKey: url as NSURL)
        return representation.uiImage
    }
}
