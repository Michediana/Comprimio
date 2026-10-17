//
//  ConversionBudget.swift
//  Comprimio iOS
//
//  Quante conversioni far girare insieme e quanta memoria concedere a
//  ImageMagick. Sul Mac le corsie seguono i core; qui li segue la memoria,
//  perché superarla non rallenta: l'app viene chiusa dal sistema.
//
//  La memoria si misura all'avvio e di nuovo a ogni batch: quella che il
//  sistema concede cambia con le altre app aperte, e il valore misurato
//  porta con sé il dispositivo (circa 2 GB su un iPhone da 4 GB, 3,5–4 GB su
//  uno da 6–8 GB, di più su un iPad M). Le stime per corsia vengono dalle
//  misure nel simulatore (docs/ROADMAP-iOS.md, «Memoria»).
//

import Foundation
import os

struct ConversionBudget {
    /// Memoria che il sistema concede ancora all'app al momento della misura.
    let availableMemory: UInt64

    /// Il budget con la memoria disponibile adesso.
    static func measure() -> ConversionBudget {
        ConversionBudget(availableMemory: measureAvailableMemory())
    }

    /// Memoria stimata per una corsia nel caso peggiore: i pixel di
    /// ImageMagick entro il limite (picco di 221 MB con 256 MB su una foto da
    /// 48 MP), più ciò che il limite non vede, cioè la decodifica di ImageIO
    /// per HEIC e raw e gli encoder.
    private static let perLane: UInt64 = 600 << 20
    /// Limite delle risorse di ImageMagick per ogni corsia.
    static let pixelsPerLane: UInt64 = 256 << 20

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

    /// Il limite dopo un avviso di memoria: quello di una corsia sola, anche
    /// se ne girano di più. Le conversioni in corso continuano, con i pixel
    /// in eccesso nella cache su disco invece che in memoria.
    static var pressureMemoryLimit: UInt64 { pixelsPerLane }

    private static func measureAvailableMemory() -> UInt64 {
        let available = UInt64(os_proc_available_memory())
        // Nel simulatore non c'è un limite per processo e la funzione
        // restituisce 0: si ripiega su una frazione della memoria fisica.
        return available > 0 ? available : ProcessInfo.processInfo.physicalMemory / 4
    }
}
