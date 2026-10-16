//
//  LibraryEngine.swift
//  MagickEngine
//
//  ImageMagick dentro il processo. Accetta gli stessi argomenti del binario
//  `magick` usato dall'app Mac, così `ImageMagick.arguments(…)` resta unica;
//  cambiano solo avanzamento, annullamento ed errori, che lì passano dal
//  sottoprocesso e qui da callback.
//

import Foundation
import ImageMagick

public struct MagickError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Avanzamento riportato da ImageMagick.
public struct MagickProgress: Sendable {
    /// Operazione in corso, come la chiama ImageMagick ("Resize/Image",
    /// "Save/Image"…). È lo stesso testo che `-monitor` stampa sul Mac.
    public let tag: String
    /// Frazione 0…1 *dell'operazione*: riparte da zero a ognuna.
    public let fraction: Double
}

/// Permette di interrompere le conversioni ancora in corso.
///
/// Sul Mac si termina il processo `magick`; qui non c'è un processo, e
/// l'interruzione passa dal callback di avanzamento: restituire `MagickFalse`
/// fa abbandonare a ImageMagick l'operazione corrente.
public final class MagickCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    public var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

public enum LibraryEngine {

    // MARK: - Avvio

    /// `MagickWandGenesis` una volta sola, prima di qualsiasi altra chiamata.
    private static let genesis: Void = {
        MagickWandGenesis()
        // I gestori predefiniti stampano su stderr, e quello degli errori
        // fatali chiama `exit()`. I primi due raccolgono i messaggi per chi
        // ha avviato la conversione; il terzo non può evitare l'uscita
        // (ImageMagick la esegue comunque dopo averlo chiamato), ma la si
        // raggiunge solo se un'allocazione fallisce, e i limiti delle risorse
        // servono a non arrivarci.
        _ = SetErrorHandler(collectMessage)
        _ = SetWarningHandler(collectWarning)
        _ = SetFatalErrorHandler(reportFatal)
    }()

    /// Versione di ImageMagick, per esempio "7.1.2-30".
    public static var version: String {
        _ = genesis
        return String(cString: GetMagickVersion(nil))
            .split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    /// Profondità del quantum con cui è stata compilata la libreria.
    public static var quantumDepth: Int {
        _ = genesis
        var depth: Int = 0
        _ = GetMagickQuantumDepth(&depth)
        return depth
    }

    /// Formati che questa build sa scrivere, in maiuscolo come sul Mac.
    public static var writableFormats: Set<String> {
        _ = genesis
        let exception = AcquireExceptionInfo()
        defer { DestroyExceptionInfo(exception) }
        var count = 0
        guard let list = GetMagickInfoList("*", &count, exception) else { return [] }
        defer { RelinquishMagickMemory(UnsafeMutableRawPointer(mutating: list)) }

        var result: Set<String> = []
        for index in 0..<count {
            guard let info = list[index], GetImageEncoder(info) != nil,
                  let name = GetMagickName(info) else { continue }
            result.insert(String(cString: name).uppercased())
        }
        return result
    }

    // MARK: - Risorse

    /// Limiti oltre i quali ImageMagick sposta i pixel nella cache su disco
    /// (nella cartella temporanea dell'app) invece di allocare memoria. Su
    /// iPhone è la differenza tra una conversione lenta e l'app chiusa dal
    /// sistema.
    public static func setMemoryLimit(_ bytes: UInt64) {
        _ = genesis
        _ = SetMagickResourceLimit(MemoryResource, MagickSizeType(bytes))
        _ = SetMagickResourceLimit(MapResource, MagickSizeType(bytes) * 2)
    }

    // MARK: - Esecuzione

    /// Esegue un comando `magick` dentro il processo. `arguments` non
    /// contiene il nome del programma: è ciò che il Mac passa a `Process`.
    ///
    /// Bloccante: va chiamato fuori dal main thread. Più chiamate possono
    /// girare in parallelo su thread diversi.
    public static func run(
        arguments: [String],
        cancellation: MagickCancellation? = nil,
        onProgress: (@Sendable (MagickProgress) -> Void)? = nil
    ) throws {
        _ = genesis
        if cancellation?.cancelled == true {
            throw MagickError(message: String(localized: "Operation cancelled."))
        }

        let context = RunContext(cancellation: cancellation, onProgress: onProgress)
        let messages = MessageCollector()
        Thread.current.threadDictionary[MessageCollector.key] = messages
        defer { Thread.current.threadDictionary[MessageCollector.key] = nil }

        guard let imageInfo = AcquireImageInfo(), let exception = AcquireExceptionInfo() else {
            throw MagickError(message: String(localized: "ImageMagick could not complete the operation."))
        }
        defer {
            DestroyExceptionInfo(exception)
            DestroyImageInfo(imageInfo)
        }

        // L'ImageInfo passato è quello che la CLI usa davvero, e ogni
        // immagine letta ne eredita il monitor: niente `-monitor`.
        let unmanaged = Unmanaged.passRetained(context)
        defer { unmanaged.release() }
        _ = SetImageInfoProgressMonitor(imageInfo, progressMonitor, unmanaged.toOpaque())

        // argv in stile C, con il nome del programma davanti.
        var argv: [UnsafeMutablePointer<CChar>?] = (["magick"] + arguments).map { strdup($0) }
        defer { argv.forEach { free($0) } }
        argv.append(nil)

        let status = argv.withUnsafeMutableBufferPointer { buffer in
            MagickImageCommand(imageInfo, Int32(arguments.count + 1), buffer.baseAddress, nil, exception)
        }
        // Le eccezioni rimaste (quelle che la CLI non ha già consumato).
        if exception.pointee.severity.rawValue >= ErrorException.rawValue {
            messages.append(severity: exception.pointee.severity,
                            reason: exception.pointee.reason,
                            description: exception.pointee.description)
        }

        if cancellation?.cancelled == true {
            throw MagickError(message: String(localized: "Operation cancelled."))
        }
        if status == MagickFalse || messages.hasErrors {
            throw MagickError(message: messages.errorText.isEmpty
                ? String(localized: "ImageMagick could not complete the operation.")
                : messages.errorText)
        }
    }
}

// MARK: - Callback C

/// Quel che serve al callback di avanzamento, passato come `client_data`.
private final class RunContext {
    let cancellation: MagickCancellation?
    let onProgress: (@Sendable (MagickProgress) -> Void)?
    var lastTag = ""
    var lastFraction = -1.0

    init(cancellation: MagickCancellation?, onProgress: (@Sendable (MagickProgress) -> Void)?) {
        self.cancellation = cancellation
        self.onProgress = onProgress
    }
}

private func progressMonitor(
    _ tag: UnsafePointer<CChar>?,
    _ offset: MagickOffsetType,
    _ extent: MagickSizeType,
    _ clientData: UnsafeMutableRawPointer?
) -> MagickBooleanType {
    guard let clientData else { return MagickTrue }
    let context = Unmanaged<RunContext>.fromOpaque(clientData).takeUnretainedValue()
    if context.cancellation?.cancelled == true { return MagickFalse }

    guard let onProgress = context.onProgress, extent > 0 else { return MagickTrue }
    let name = tag.map { String(cString: $0) } ?? ""
    // I contatori partono da zero: `0 of 3000` è la prima riga di 3000.
    let fraction = min(1, Double(offset + 1) / Double(extent))
    // Un aggiornamento per riga di pixel sarebbero migliaia di refresh per
    // immagine, come sul Mac con `-monitor`.
    if name != context.lastTag || abs(fraction - context.lastFraction) >= 0.01 {
        context.lastTag = name
        context.lastFraction = fraction
        onProgress(MagickProgress(tag: name, fraction: fraction))
    }
    return MagickTrue
}

/// Messaggi raccolti durante una conversione. Ogni conversione gira in modo
/// sincrono su un thread, e i gestori di ImageMagick non hanno un contesto:
/// il collegamento passa dal dizionario del thread.
private final class MessageCollector {
    static let key = "com.michediana.Comprimio.MagickMessages"

    private(set) var errors: [String] = []

    var hasErrors: Bool { !errors.isEmpty }
    var errorText: String { errors.joined(separator: "\n") }

    func append(
        severity: ExceptionType,
        reason: UnsafePointer<CChar>?,
        description: UnsafePointer<CChar>?
    ) {
        guard severity.rawValue >= ErrorException.rawValue else { return }
        var text = reason.map { String(cString: $0) } ?? ""
        if let description {
            text += " (\(String(cString: description)))"
        }
        if !text.isEmpty, errors.last != text { errors.append(text) }
    }

    static var current: MessageCollector? {
        Thread.current.threadDictionary[key] as? MessageCollector
    }
}

private func collectMessage(
    _ severity: ExceptionType,
    _ reason: UnsafePointer<CChar>?,
    _ description: UnsafePointer<CChar>?
) {
    MessageCollector.current?.append(severity: severity, reason: reason, description: description)
}

/// Gli avvisi non fanno fallire la conversione, come sul Mac dove
/// `magick` esce comunque con 0.
private func collectWarning(
    _ severity: ExceptionType,
    _ reason: UnsafePointer<CChar>?,
    _ description: UnsafePointer<CChar>?
) {}

private func reportFatal(
    _ severity: ExceptionType,
    _ reason: UnsafePointer<CChar>?,
    _ description: UnsafePointer<CChar>?
) {
    let text = [reason, description].compactMap { $0.map { String(cString: $0) } }.joined(separator: " ")
    NSLog("ImageMagick: errore fatale, l'app verrà chiusa: %@", text)
}
