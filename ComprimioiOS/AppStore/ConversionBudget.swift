//
//  ConversionBudget.swift
//  Comprimio iOS
//
//  Quante conversioni far girare insieme e quanta memoria concedere a
//  ImageMagick. Sul Mac le corsie seguono i core; qui li segue la memoria,
//  perché superarla non rallenta: l'app viene chiusa dal sistema.
//
//  Valori di partenza presi dalle misure nel simulatore (docs/ROADMAP-iOS.md,
//  «Memoria»): da tarare sui dispositivi nella fase 6.
//

import Foundation
import os

struct ConversionBudget {
    /// Memoria che il sistema concede ancora all'app all'avvio.
    let availableMemory: UInt64

    static let current = ConversionBudget(availableMemory: Self.measureAvailableMemory())

    /// Memoria stimata per una corsia nel caso peggiore: i pixel di
    /// ImageMagick entro il limite (picco di 221 MB con 256 MB su una foto da
    /// 48 MP), più ciò che il limite non vede, cioè la decodifica di ImageIO
    /// per HEIC e raw e gli encoder.
    private static let perLane: UInt64 = 600 << 20
    /// Limite delle risorse di ImageMagick per ogni corsia.
    private static let pixelsPerLane: UInt64 = 256 << 20

    /// Corsie per il formato di uscita. AVIF e HEIC ne hanno una sola: i loro
    /// encoder hanno già un pool di thread proprio.
    func lanes(for format: OutputFormat) -> Int {
        if format.family == .avif || format.family == .heic { return 1 }
        return generalLanes
    }

    /// Metà della memoria disponibile, divisa per corsia; mai più dei core
    /// meno uno (la UI deve restare fluida) e mai più di tre.
    var generalLanes: Int {
        let byMemory = Int(availableMemory / 2 / Self.perLane)
        let byCores = ProcessInfo.processInfo.activeProcessorCount - 1
        return max(1, min(byMemory, byCores, 3))
    }

    /// Il limite di ImageMagick vale per tutto il processo, non per thread:
    /// è quello di una corsia moltiplicato per le corsie. Oltre, i pixel
    /// vanno nella cache su disco nella cartella temporanea.
    var memoryLimit: UInt64 {
        Self.pixelsPerLane * UInt64(generalLanes)
    }

    private static func measureAvailableMemory() -> UInt64 {
        let available = UInt64(os_proc_available_memory())
        // Nel simulatore non c'è un limite per processo e la funzione
        // restituisce 0: si ripiega su una frazione della memoria fisica.
        return available > 0 ? available : ProcessInfo.processInfo.physicalMemory / 4
    }
}
