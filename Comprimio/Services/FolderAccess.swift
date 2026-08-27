//
//  FolderAccess.swift
//  Comprimio
//
//  Accesso alle cartelle in cui l'app scrive.
//
//  Sotto sandbox scegliere dei file dà accesso a quei file, non alla cartella
//  che li contiene: scrivere il risultato accanto all'originale — che è quello
//  che fanno «sottocartella» e «stessa cartella» — richiede un permesso che
//  quel pannello non ha concesso. E un permesso concesso vale finché l'app
//  resta aperta: per ritrovare al lancio successivo la cartella di
//  destinazione scelta una volta sola serve un bookmark con security scope.
//
//  Qui stanno entrambe le cose: i bookmark, e l'apertura degli accessi che ne
//  derivano. `magick` non ha bisogno di nulla in più, perché eredita la
//  sandbox del processo che lo lancia, estensioni comprese.
//

import AppKit
import Foundation

@MainActor
final class FolderAccess {
    static let shared = FolderAccess()

    private static let defaultsKey = "folderBookmarks"

    /// Percorso della cartella → bookmark che la ritrova al lancio successivo.
    private var bookmarks: [String: Data]
    /// Accessi aperti in questa sessione, da chiudere all'uscita. La URL va
    /// tenuta viva: è quella su cui è stato aperto lo scope.
    private var open: [String: URL] = [:]

    private init() {
        bookmarks = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: Data]) ?? [:]
    }

    // MARK: - Uso

    /// Vero se l'app può creare file dentro `folder`, eventualmente creando
    /// prima la cartella stessa. Si risale al primo antenato esistente: per
    /// «sottocartella» la destinazione non esiste ancora, e il permesso che
    /// conta è quello di chi la conterrà.
    func canWrite(to folder: URL) -> Bool {
        let fm = FileManager.default
        var candidate = folder.standardizedFileURL
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue && fm.isWritableFile(atPath: candidate.path)
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return false
    }

    /// Riapre l'accesso a una cartella già autorizzata in passato. Vero se ora
    /// è raggiungibile — perché il bookmark ha funzionato, o perché l'accesso
    /// non serviva (una cartella dentro il container dell'app).
    @discardableResult
    func restore(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        if open[path] != nil { return true }
        guard let data = bookmarks[path] else { return canWrite(to: folder) }

        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            bookmarks[path] = nil
            persist()
            return false
        }
        guard resolved.startAccessingSecurityScopedResource() else {
            return canWrite(to: folder)
        }
        open[path] = resolved
        // Un bookmark diventa stale quando la cartella viene spostata o
        // rinominata: risolve ancora, ma la prossima volta no.
        if stale { remember(resolved) }
        return true
    }

    /// Registra una cartella a cui l'utente ha appena dato accesso, così da
    /// ritrovarla ai lanci successivi.
    func remember(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard let data = try? folder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        bookmarks[path] = data
        persist()
        if open[path] == nil, folder.startAccessingSecurityScopedResource() {
            open[path] = folder
        }
    }

    /// Chiede all'utente il permesso di scrivere in `folder`, con il pannello
    /// già puntato lì. Vero se l'ha concesso — anche scegliendo una cartella
    /// più in alto, che comprende comunque la destinazione.
    func requestAccess(to folder: URL) -> Bool {
        let target = nearestExisting(folder)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = target
        panel.prompt = String(localized: "Grant Access")
        panel.message = String(localized: """
            Comprimio needs your permission to save the results in “\(target.lastPathComponent)”. \
            Confirm the folder to continue.
            """)
        guard panel.runModal() == .OK, let chosen = panel.url else { return false }
        remember(chosen)
        return canWrite(to: folder)
    }

    /// Da chiamare all'uscita: gli accessi aperti vanno chiusi.
    func releaseAll() {
        for url in open.values { url.stopAccessingSecurityScopedResource() }
        open.removeAll()
    }

    // MARK: - Dettagli

    private func nearestExisting(_ folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.standardizedFileURL
        while candidate.path != "/" && !fm.fileExists(atPath: candidate.path) {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
    }

    private func persist() {
        UserDefaults.standard.set(bookmarks, forKey: Self.defaultsKey)
    }
}
