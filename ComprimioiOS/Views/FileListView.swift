//
//  FileListView.swift
//  Comprimio iOS
//
//  La lista dei file: miniatura, nome, dimensioni, esito. Sul Mac è una
//  tabella a colonne; qui le stesse informazioni stanno in due righe per
//  elemento. Sull'iPad sta nella sidebar e seleziona; sull'iPhone ogni riga
//  apre l'anteprima.
//

import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isDropTargeted = false

    /// Righe che portano all'anteprima (`NavigationLink` con l'ID del file)
    /// invece di selezionare.
    var navigates = false

    var body: some View {
        list
            .overlay {
                if store.items.isEmpty { EmptyListPlaceholder(showsActions: navigates) }
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

    // Una `List` con la selezione dentro una pila seleziona solo in modalità
    // modifica: per navigare serve quella senza.
    @ViewBuilder
    private var list: some View {
        if navigates {
            List { rows }
                .listStyle(.plain)
        } else {
            List(selection: $store.selection) { rows }
                .listStyle(.sidebar)
        }
    }

    private var rows: some View {
        ForEach(store.items) { item in
            Group {
                if navigates {
                    NavigationLink(value: item.id) { FileRow(item: item) }
                } else {
                    FileRow(item: item).tag(item.id)
                }
            }
            .contextMenu { menu(for: item) }
        }
        .onDelete { offsets in
            let ids = Set(offsets.map { store.items[$0].id })
            store.remove(ids)
        }
        .deleteDisabled(store.isProcessing)
    }

    @ViewBuilder
    private func menu(for item: ImageItem) -> some View {
        let ids = store.selection.contains(item.id) ? store.selection : [item.id]
        if let output = item.outputURL {
            ShareLink(item: output) {
                Label("Share Result", systemImage: "square.and.arrow.up")
            }
            if !store.outputsToSave(in: ids).isEmpty {
                Button {
                    store.saveOutputsToPhotos(ids)
                } label: {
                    Label("Save to Photos", systemImage: "photo.badge.plus")
                }
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
    @EnvironmentObject private var store: AppStore
    /// Sull'iPhone i pulsanti per cominciare: le Foto per prime, perché è
    /// lì che stanno le immagini di un telefono.
    var showsActions = false

    var body: some View {
        ContentUnavailableView {
            Label("No images", systemImage: "photo.on.rectangle.angled")
        } description: {
            if showsActions {
                Text("Choose the photos to compress, or images from Files.")
            } else {
                Text("Add photos or files with the + button, or drag them here.")
            }
        } actions: {
            if showsActions {
                Button {
                    store.importRequest = .photos
                } label: {
                    Label("Choose Photos", systemImage: "photo.on.rectangle")
                }
                .glassButton(prominent: true)
                .controlSize(.large)

                Button("Browse Files") { store.importRequest = .files }
            }
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
        // L'immagine in un overlay: prende la misura del riquadro e non la
        // propria, così una miniatura larga non esce dal quadrato.
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
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
