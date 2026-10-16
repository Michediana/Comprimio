//
//  AppStore+Import.swift
//  Comprimio iOS
//
//  Le altre strade da cui arrivano le immagini, oltre a `.fileImporter` e
//  «Apri con» (che danno URL security-scoped e passano da `add(urls:)`):
//  la libreria Foto e il trascinamento da altre app.
//

import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Una foto scelta con PhotosPicker, copiata in `ImportInbox`. Il file
/// ricevuto è temporaneo e sparisce appena la chiusura restituisce.
struct PickedImage: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedImage(url: try ImportInbox.store(received.file))
        }
    }
}

extension AppStore {

    // MARK: - Foto

    /// Importa le foto scelte. Arrivano nel formato originale (HEIC, ProRAW,
    /// JPEG…) se il picker è creato con `preferredItemEncoding: .current`:
    /// una copia ricodificata in JPEG non avrebbe senso in un compressore.
    func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !selection.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for item in selection {
                if let picked = try? await item.loadTransferable(type: PickedImage.self) {
                    urls.append(picked.url)
                }
            }
            add(urls: urls)
        }
    }

    // MARK: - Trascinamento

    /// Accetta file e cartelle trascinati da File o da altre app. Se il
    /// mittente offre l'originale «in loco» si lavora su quello, con
    /// l'accesso security-scoped; altrimenti su una copia.
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let accepted = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !accepted.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in accepted {
                if let url = await Self.loadDropped(provider) { urls.append(url) }
            }
            add(urls: urls)
        }
        return true
    }

    private nonisolated static func loadDropped(_ provider: NSItemProvider) async -> URL? {
        // Il tipo più specifico che il mittente registra, così un HEIC resta
        // HEIC invece di arrivare come generica «immagine».
        let type = provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
            ? UTType.folder.identifier
            : provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier

        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                if inPlace {
                    continuation.resume(returning: url)
                } else {
                    // La copia del mittente vale solo dentro questa chiusura.
                    // Il nome suggerito a volte ha già l'estensione, a volte no.
                    let name = suggestedName.map { name in
                        url.pathExtension.isEmpty || !(name as NSString).pathExtension.isEmpty
                            ? name : "\(name).\(url.pathExtension)"
                    }
                    continuation.resume(returning: try? ImportInbox.store(url, name: name))
                }
            }
        }
    }
}
