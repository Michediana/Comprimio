//
//  OutputDestination.swift
//  Comprimio iOS
//
//  Dove finiscono i file convertiti. Sul Mac si scrive accanto agli originali
//  o in una cartella qualsiasi; su iOS un file scelto in File dà accesso a sé
//  stesso, non alla cartella che lo contiene, e una foto non ha cartella.
//  Le destinazioni sono quindi tre: la cartella dell'app (visibile in File),
//  una cartella scelta dall'utente, la libreria Foto.
//
//  È una preferenza solo iOS: `ConversionSettings.destination` resta quella
//  del Mac, e su iOS il nome del file lo decide comunque `outputURL`.
//

import Foundation

enum OutputDestination: String, CaseIterable, Identifiable {
    case appFolder
    case chosenFolder
    case photos

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appFolder: return String(localized: "Comprimio folder in Files")
        case .chosenFolder: return String(localized: "A folder you choose")
        case .photos: return String(localized: "Photos library")
        }
    }

    var symbol: String {
        switch self {
        case .appFolder: return "folder"
        case .chosenFolder: return "folder.badge.person.crop"
        case .photos: return "photo.on.rectangle"
        }
    }

    private static let key = "iosOutputDestination"

    static func load() -> OutputDestination {
        UserDefaults.standard.string(forKey: key).flatMap(OutputDestination.init(rawValue:)) ?? .appFolder
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
    }
}

/// La cartella scelta dall'utente, ricordata con un bookmark: l'URL da solo
/// non riapre l'accesso dopo un riavvio.
enum SavedOutputFolder {
    private static let key = "iosOutputFolderBookmark"

    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key)
    }

    /// L'URL della cartella, con il bookmark rinnovato se il sistema lo
    /// considera scaduto (la cartella è stata spostata o rinominata).
    /// L'accesso va aperto da chi lo usa.
    static func resolve() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        if stale, url.startAccessingSecurityScopedResource() {
            try? save(url)
            url.stopAccessingSecurityScopedResource()
        }
        return url
    }
}

/// Copie dei file che arrivano senza un originale raggiungibile: le foto
/// scelte con PhotosPicker e i file trascinati che il mittente non offre
/// «in loco». Una sottocartella per file, così due `IMG_0001.HEIC` non si
/// sovrascrivono; vanno via quando il file esce dalla lista.
enum ImportInbox {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Comprimio-import", isDirectory: true)

    /// Copia `file` nella cartella e restituisce la copia.
    static func store(_ file: URL, name: String? = nil) throws -> URL {
        let slot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        let destination = slot.appendingPathComponent(name ?? file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }

    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Cancella le copie che nessun elemento della lista usa più.
    static func removeUnused(keeping urls: [URL]) {
        let used = Set(urls.filter(contains).map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let slots = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for slot in slots where !used.contains(slot.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: slot)
        }
    }
}
