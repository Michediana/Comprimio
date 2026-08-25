//
//  ImageMagick.swift
//  Comprimio
//
//  Individuazione del binario `magick` e costruzione/esecuzione dei comandi.
//

import Foundation

struct MagickError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Avanzamento riportato da `magick -monitor`.
struct MagickProgress: Sendable {
    /// Fase in corso, già tradotta ("carico", "salvo"…).
    let phase: String
    /// Frazione 0…1 *della fase*: `magick` riparte da zero a ogni operazione.
    let fraction: Double
}

/// Permette di terminare i processi `magick` ancora in corso.
///
/// Annullare un `Task` non tocca i sottoprocessi: senza questo, chiudere
/// un'anteprima o premere Annulla lascia `magick` a macinare in background,
/// e su un file grande può volerci molto.
final class MagickCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Process] = []
    private var isCancelled = false

    /// Registra un processo appena avviato. `false` se è già stato annullato:
    /// in quel caso il chiamante non deve nemmeno partire.
    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        running.append(process)
        return true
    }

    func unregister(_ process: Process) {
        lock.lock()
        running.removeAll { $0 === process }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let snapshot = running
        running = []
        lock.unlock()
        for process in snapshot where process.isRunning {
            process.terminate()
        }
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }
}

/// Da dove arriva il binario `magick` che stiamo usando.
enum MagickSource: Sendable {
    case bundled          // incluso in Comprimio.app
    case system           // installato sulla macchina (Homebrew, MacPorts…)

    var label: String {
        switch self {
        case .bundled: return "incluso nell'app"
        case .system: return "installato sul sistema"
        }
    }
}

/// Binario `magick` con l'ambiente che gli serve per trovare i propri moduli.
struct MagickLocation: Sendable {
    let executable: URL
    let environment: [String: String]
    let source: MagickSource
}

struct MagickInstall: Sendable {
    let location: MagickLocation
    let version: String
    let writableFormats: Set<String>

    var executable: URL { location.executable }
    var source: MagickSource { location.source }

    func supports(_ format: OutputFormat) -> Bool {
        guard let name = format.magickName else { return true }
        return writableFormats.contains(name)
    }
}

/// Manifest scritto da Scripts/bundle-imagemagick.py al momento della build.
/// I percorsi contengono il quantum (Q16HDRI), che dipende da come è stata
/// compilata quell'installazione: leggerli è più sicuro che ricostruirli.
private struct BundleManifest: Decodable {
    let version: String
    let executable: String
    let coderModulePath: String?
    let filterModulePath: String?
    let configurePaths: [String]
}

/// Qualità richiesta per l'anteprima.
enum PreviewQuality: Equatable, Sendable {
    /// Copia ridotta: veloce, e per un file grande la dimensione risultante
    /// è solo una stima.
    case fast(fit: Int)
    /// Pixel reali, come li produrrà l'elaborazione vera.
    case full

    var fit: Int? {
        if case .fast(let fit) = self { return fit }
        return nil
    }
}

enum ImageMagick {

    /// Percorso impostato manualmente dall'utente, se presente.
    static var customPath: String? {
        get { UserDefaults.standard.string(forKey: "magickPath") }
        set { UserDefaults.standard.set(newValue, forKey: "magickPath") }
    }

    private static let searchPaths = [
        "/opt/homebrew/bin/magick",
        "/usr/local/bin/magick",
        "/opt/local/bin/magick",
        "/usr/bin/magick"
    ]

    // MARK: - Discovery

    static func locate() -> MagickLocation? {
        // Un percorso scelto a mano dall'utente ha la precedenza su tutto.
        if let custom = customPath, !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return MagickLocation(
                executable: URL(fileURLWithPath: custom),
                environment: ProcessInfo.processInfo.environment,
                source: .system
            )
        }
        if let bundled = bundledLocation() {
            return bundled
        }
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return systemLocation(URL(fileURLWithPath: path))
        }
        // Ultimo tentativo: chiedi alla shell di login (PATH personalizzato).
        if let found = try? shellWhich(), FileManager.default.isExecutableFile(atPath: found) {
            return systemLocation(URL(fileURLWithPath: found))
        }
        return nil
    }

    private static func systemLocation(_ executable: URL) -> MagickLocation {
        MagickLocation(
            executable: executable,
            environment: ProcessInfo.processInfo.environment,
            source: .system
        )
    }

    /// La copia inclusa in Contents/Resources/ImageMagick, se presente.
    static func bundledLocation() -> MagickLocation? {
        guard let root = Bundle.main.resourceURL?
            .appendingPathComponent("ImageMagick", isDirectory: true) else { return nil }

        let manifestURL = root.appendingPathComponent("imagemagick-bundle.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(BundleManifest.self, from: data)
        else { return nil }

        let executable = root.appendingPathComponent(manifest.executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        // Un binario per l'architettura sbagliata è comunque un file eseguibile:
        // senza questo controllo verrebbe scelto lo stesso e ogni conversione
        // fallirebbe con «Bad CPU type», invece di lasciare il posto a un
        // ImageMagick installato sul sistema.
        guard runsOnThisMac(executable) else { return nil }

        func absolute(_ relative: String) -> String {
            root.appendingPathComponent(relative).path
        }

        var environment = ProcessInfo.processInfo.environment
        if let coders = manifest.coderModulePath {
            environment["MAGICK_CODER_MODULE_PATH"] = absolute(coders)
        }
        if let filters = manifest.filterModulePath {
            environment["MAGICK_FILTER_MODULE_PATH"] = absolute(filters)
        }
        if !manifest.configurePaths.isEmpty {
            environment["MAGICK_CONFIGURE_PATH"] = manifest.configurePaths
                .map(absolute)
                .joined(separator: ":")
        }
        // PATH ristretto: i delegate esterni non presenti nel bundle sono già
        // stati rimossi da delegates.xml, quindi il risultato non deve
        // dipendere da cosa c'è installato sulla macchina dell'utente.
        environment["PATH"] = "\(root.appendingPathComponent("bin").path):/usr/bin:/bin"

        return MagickLocation(executable: executable, environment: environment, source: .bundled)
    }

    /// Architettura di questo processo, nella codifica cputype di Mach-O.
    private static var hostCPUType: UInt32 {
        #if arch(arm64)
        return 0x0100_000C          // CPU_TYPE_ARM64
        #elseif arch(x86_64)
        return 0x0100_0007          // CPU_TYPE_X86_64
        #else
        return 0
        #endif
    }

    /// Vero se il Mach-O contiene l'architettura di questo processo.
    ///
    /// Legge l'intestazione invece di provare a eseguire il binario: la
    /// scoperta avviene all'avvio, e un tentativo fallito costerebbe comunque
    /// il tempo di uno spawn.
    static func runsOnThisMac(_ executable: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return false }
        let header = [UInt8](data)

        func word(_ offset: Int, bigEndian: Bool) -> UInt32 {
            var value: UInt32 = 0
            for index in 0..<4 {
                value = value << 8 | UInt32(header[offset + (bigEndian ? index : 3 - index)])
            }
            return value
        }

        // Mach-O singolo: il cputype segue subito il magic.
        let magic = word(0, bigEndian: false)
        if magic == 0xFEED_FACF || magic == 0xFEED_FACE {
            return word(4, bigEndian: false) == hostCPUType
        }
        // Mach-O fat: l'intestazione è big-endian, seguita da una voce per
        // architettura (20 byte, 32 nella variante a 64 bit).
        let fatMagic = word(0, bigEndian: true)
        if fatMagic == 0xCAFE_BABE || fatMagic == 0xCAFE_BABF {
            let stride = fatMagic == 0xCAFE_BABE ? 20 : 32
            for index in 0..<Int(word(4, bigEndian: true)) {
                let offset = 8 + index * stride
                guard offset + 4 <= header.count else { break }
                if word(offset, bigEndian: true) == hostCPUType { return true }
            }
        }
        return false
    }

    private static func shellWhich() throws -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let out = try run(URL(fileURLWithPath: shell), arguments: ["-l", "-c", "command -v magick"])
        let trimmed = out.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Interroga il binario per versione e formati scrivibili.
    static func inspect(_ location: MagickLocation) throws -> MagickInstall {
        let versionOut = try run(location, arguments: ["-version"])
        guard versionOut.exitCode == 0 else {
            throw MagickError(message: "Impossibile eseguire \(location.executable.path).")
        }
        let version = versionOut.standardOutput
            .split(separator: "\n").first
            .map { String($0).replacingOccurrences(of: "Version: ", with: "") } ?? "ImageMagick"

        let formatsOut = try? run(location, arguments: ["-list", "format"])
        let writable = parseWritableFormats(formatsOut?.standardOutput ?? "")
        return MagickInstall(location: location, version: version, writableFormats: writable)
    }

    static func parseWritableFormats(_ output: String) -> Set<String> {
        var result: Set<String> = []
        for line in output.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 3 else { continue }
            let name = tokens[0].hasSuffix("*") ? String(tokens[0].dropLast()) : tokens[0]
            // La colonna dei permessi è del tipo "rw+", "r--", "-w-".
            let isModeColumn: (String) -> Bool = { token in
                token.count == 3 && token.allSatisfy { "rw+-".contains($0) }
            }
            guard let mode = tokens.first(where: isModeColumn), mode.contains("w") else { continue }
            result.insert(name.uppercased())
        }
        return result
    }

    // MARK: - Costruzione argomenti

    /// Argomenti completi per convertire `input` in `output` con `settings`.
    /// `preview` distingue l'anteprima veloce (ridotta) da quella a piena
    /// risoluzione, richiesta quando l'utente ingrandisce per confrontare
    /// i pixel reali.
    static func arguments(
        settings: ConversionSettings,
        input: URL,
        output: URL,
        preview: PreviewQuality? = nil,
        monitor: Bool = false
    ) -> [String] {
        let format = settings.targetFormat(for: input)
        // `-monitor` è un'impostazione: vale solo per le operazioni che seguono.
        var args: [String] = monitor ? ["-monitor", input.path] : [input.path]

        // Per l'anteprima riduco subito la sorgente: applicare prima le
        // operazioni dell'utente su un file enorme (un ingrandimento al 287%
        // di un 9000×9000 sono 667 megapixel) rende l'anteprima inutilizzabile.
        // Il risultato resta rappresentativo e la dimensione è già segnalata
        // come stima quando l'anteprima è ridotta.
        if preview?.fit != nil {
            args += ["-resize", "4000x4000>"]
        }

        // 1. Orientamento EXIF prima di qualsiasi trasformazione geometrica.
        if settings.autoOrient { args += ["-auto-orient"] }

        if let degrees = settings.rotation.degrees { args += ["-rotate", "\(degrees)"] }
        if settings.flipHorizontal { args += ["-flop"] }
        if settings.flipVertical { args += ["-flip"] }

        // 2. Regolazioni tonali.
        if settings.brightness != 0 || settings.contrast != 0 {
            args += ["-brightness-contrast", "\(Int(settings.brightness))x\(Int(settings.contrast))"]
        }
        if settings.saturation != 0 {
            args += ["-modulate", "100,\(Int(100 + settings.saturation)),100"]
        }
        if settings.grayscale { args += ["-colorspace", "Gray"] }

        // 3. Ridimensionamento. Il filtro serve solo se ricampioniamo davvero.
        if settings.resizeMode != .none || preview?.fit != nil {
            args += ["-filter", settings.resizeFilter.magickValue]
        }
        args += resizeArguments(settings)

        // 4. Nitidezza / sfocatura, dopo il resize.
        if settings.sharpen > 0 {
            args += ["-unsharp", String(format: "0x%.1f+%.1f+0.02", 1.0, settings.sharpen)]
        }
        if settings.blur > 0 {
            args += ["-blur", String(format: "0x%.1f", settings.blur)]
        }

        // 5. L'anteprima non ha bisogno di pixel a piena risoluzione.
        if let fit = preview?.fit {
            args += ["-resize", "\(fit)x\(fit)>"]
        }

        // 5b. Filigrana dopo il ridimensionamento: le sue misure sono percentuali
        // dell'immagine, quindi vanno calcolate su quella finale (e sull'anteprima
        // ridotta). Dopo le regolazioni di colore, così un logo resta a colori
        // anche convertendo la foto in scala di grigi; prima dell'appiattimento,
        // perché è la trasparenza a fonderla con lo sfondo.
        args += watermarkArguments(settings.watermark)

        // 6. Trasparenza: appiattisci se richiesto o se il formato non la supporta.
        if settings.flattenAlpha || !format.supportsAlpha {
            args += ["-background", settings.flattenColorHex, "-alpha", "remove", "-alpha", "off"]
        }

        if settings.convertToSRGB && !settings.grayscale {
            args += ["-colorspace", "sRGB"]
        }

        // 7. Opzioni specifiche del formato.
        args += formatArguments(settings: settings, format: format)

        // 8. Metadati: `-strip` dopo la conversione di colorspace…
        if !settings.keepMetadata { args += ["-strip"] }

        // …e il DPI dopo lo strip, che altrimenti cancellerebbe la densità.
        if settings.applyDPI {
            args += ["-units", "PixelsPerInch", "-density", "\(settings.dpi)"]
        }

        // 9. Destinazione, con prefisso di formato esplicito quando serve.
        if format == .png && settings.pngPalette {
            args += ["PNG8:" + output.path]
        } else if let name = format.magickName {
            args += ["\(name):" + output.path]
        } else {
            args += [output.path]
        }
        return args
    }

    // MARK: - Filigrana

    /// Sovrapposizione di un logo o di un testo.
    ///
    /// Tutte le misure sono percentuali della larghezza dell'immagine e vengono
    /// risolte da `magick` con `%[fx:…]` al momento della conversione, non qui:
    /// così la stessa riga di comando vale per un 6000×4000 e per l'anteprima
    /// ridotta, e la filigrana risulta proporzionata in entrambe senza che
    /// l'app debba prevedere le dimensioni di uscita.
    static func watermarkArguments(_ w: WatermarkSettings) -> [String] {
        guard w.isEffective else { return [] }

        func percent(_ value: Double) -> String { String(format: "%.6f", value / 100) }

        // Le opzioni si impostano sull'immagine di partenza, dove `w` e `h`
        // esistono; dentro le parentesi sono già semplici valori da rileggere.
        var args: [String] = [
            "-set", "option:cwmsize", "%[fx:max(1,round(w*\(percent(w.scale))))]",
            "-set", "option:cwmmargin", "%[fx:round(w*\(percent(w.margin)))]"
        ]
        if w.tile {
            args += [
                "-set", "option:cwmgap", "%[fx:max(1,round(w*\(percent(w.scale * w.tileGap / 100))))]",
                "-set", "option:cwmw", "%[fx:w]",
                "-set", "option:cwmh", "%[fx:h]"
            ]
        }
        if w.mode == .text, w.outline {
            args += ["-set", "option:cwmstroke", "%[fx:max(1,round(w*0.0015))]"]
        }

        // La filigrana si costruisce in una lista a parte: `-font`, `-fill` e
        // `-pointsize` non devono restare attaccati all'immagine di partenza.
        args.append("(")
        switch w.mode {
        case .none:
            return []
        case .image:
            args += [w.imagePath, "-resize", "%[cwmsize]x"]
        case .text:
            args += ["-background", "none"]
            if let font = w.fontFileURL { args += ["-font", font.path] }
            args += ["-fill", w.colorHex, "-pointsize", "%[cwmsize]"]
            if w.outline {
                args += ["-stroke", "#000000", "-strokewidth", "%[cwmstroke]"]
            }
            args.append("label:" + w.escapedText)
        }

        if w.rotation != 0 {
            // Senza sfondo trasparente la rotazione riempirebbe di bianco gli
            // angoli aggiunti dal riquadro ruotato.
            args += ["-background", "none", "-rotate", String(format: "%g", w.rotation)]
        }

        if w.tile {
            // Il distacco fra le ripetizioni è un bordo trasparente attorno alla
            // filigrana; `tile:` riempie poi una tela delle dimensioni esatte
            // dell'immagine, che viene sovrapposta in un colpo solo.
            args += ["-bordercolor", "none", "-border", "%[cwmgap]"]
        }
        if w.opacity < 99.5 {
            args += [
                "-alpha", "set", "-channel", "A",
                "-evaluate", "multiply", String(format: "%.4f", max(0, w.opacity / 100)),
                "+channel"
            ]
        }
        if w.tile {
            args += [
                "-write", "mpr:comprimio-watermark", "+delete",
                "-size", "%[cwmw]x%[cwmh]", "tile:mpr:comprimio-watermark"
            ]
        }
        args.append(")")

        let axes = w.position.marginAxes
        let offsetX = w.tile || !axes.x ? "0" : "%[cwmmargin]"
        let offsetY = w.tile || !axes.y ? "0" : "%[cwmmargin]"
        args += [
            "-gravity", w.tile ? "NorthWest" : w.position.gravity,
            "-geometry", "+\(offsetX)+\(offsetY)",
            "-compose", "over", "-composite",
            // `-gravity` è un'impostazione che resterebbe attiva: azzerarla evita
            // che influenzi qualunque operazione aggiunta più avanti.
            "+gravity"
        ]
        return args
    }

    private static func resizeArguments(_ s: ConversionSettings) -> [String] {
        let cap = s.doNotEnlarge ? ">" : ""
        switch s.resizeMode {
        case .none:
            return []
        case .percent:
            return ["-resize", "\(Int(s.percent))%"]
        case .fit:
            return ["-resize", "\(s.width)x\(s.height)\(cap)"]
        case .width:
            return ["-resize", "\(s.width)x\(cap)"]
        case .height:
            return ["-resize", "x\(s.height)\(cap)"]
        case .exact:
            return ["-resize", "\(s.width)x\(s.height)!"]
        case .fill:
            return ["-resize", "\(s.width)x\(s.height)^",
                    "-gravity", "center",
                    "-extent", "\(s.width)x\(s.height)"]
        }
    }

    private static func formatArguments(settings s: ConversionSettings, format: OutputFormat) -> [String] {
        var args: [String] = []

        // Le opzioni valgono per l'intera famiglia del coder: PJPEG e JPS sono
        // JPEG a tutti gli effetti, PNG24 e APNG passano dallo stesso encoder.
        switch format.family {
        case .jpeg:
            if s.jpegProgressive { args += ["-interlace", "Plane"] }
            if let sub = s.chromaSubsampling.magickValue { args += ["-sampling-factor", sub] }
        case .png:
            args += ["-define", "png:compression-level=\(s.pngCompressionLevel)"]
        case .webp:
            args += ["-define", "webp:method=\(s.webpMethod)"]
            if s.lossless { args += ["-define", "webp:lossless=true"] }
        case .jxl:
            args += ["-define", "jxl:effort=\(s.jxlEffort)"]
            // Il JPEG XL non ha un define per la codifica senza perdita:
            // la ottiene la qualità 100, che libjxl interpreta come distanza 0.
            if s.lossless { args += ["-quality", "100"] }
        default:
            break
        }

        if format.supportsQuality {
            let usesQuality = !(s.lossless && format.supportsLossless)
            // Il tetto è per formato: l'AVIF non può arrivare a 100.
            if usesQuality {
                args += ["-quality", "\(min(Int(s.quality), format.maxQuality))"]
            }
        }
        return args
    }

    // MARK: - Percorso di destinazione

    static func outputURL(for input: URL, settings: ConversionSettings) -> URL {
        let format = settings.targetFormat(for: input)
        let ext = format.fileExtension ?? input.pathExtension
        let base = input.deletingPathExtension().lastPathComponent
        let fileName = "\(settings.namePrefix)\(base)\(settings.nameSuffix).\(ext)"

        let folder: URL
        switch settings.destination {
        case .sameFolder:
            folder = input.deletingLastPathComponent()
        case .subfolder:
            let name = settings.subfolderName.isEmpty ? "Comprimio" : settings.subfolderName
            folder = input.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        case .customFolder:
            folder = settings.customFolderURL ?? input.deletingLastPathComponent()
        }
        return folder.appendingPathComponent(fileName)
    }

    /// Evita di sovrascrivere aggiungendo `-1`, `-2`, … se necessario.
    static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var index = 1
        while true {
            let candidate = base.deletingLastPathComponent()
                .appendingPathComponent("\(base.lastPathComponent)-\(index)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    // MARK: - Avanzamento

    /// Etichette per i tag che `magick` usa nelle righe di `-monitor`.
    /// Sono decine e cambiano da versione a versione: quelle che contano sono
    /// le fasi lunghe, il resto ricade su un generico "elaboro".
    private static let phaseLabels: [String: String] = [
        "load": "carico",
        "save": "salvo",
        "resize": "ridimensiono",
        "modulate": "regolo i colori",
        "function": "regolo i colori",
        "colorspace": "converto il colore",
        "morphology": "applico i filtri",
        "sharpen": "applico i filtri",
        "blur": "applico i filtri",
        "rotate": "ruoto",
        "extent": "ritaglio"
    ]

    /// Interpreta una riga di `-monitor`, del tipo
    /// `resize image[foto.jpg]: 1200 of 3000, 40% complete`.
    ///
    /// La percentuale stampata è troncata all'intero, quindi la frazione arriva
    /// dai due contatori; il nome del file può contenere qualunque cosa, per cui
    /// i riferimenti sono `" of "` e `"% complete"`, non le virgole o i due punti.
    static func parseMonitorLine(_ line: String) -> MagickProgress? {
        guard let complete = line.range(of: "% complete") else { return nil }
        let head = line[line.startIndex..<complete.lowerBound]
        guard let of = head.range(of: " of ", options: .backwards) else { return nil }

        func numbers(_ text: Substring) -> [Double] {
            text.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        }
        guard let offset = numbers(head[head.startIndex..<of.lowerBound]).last,
              let extent = numbers(head[of.upperBound...]).first, extent > 0
        else { return nil }

        let tagEnd = head.firstIndex(where: { $0 == "[" || $0 == ":" }) ?? of.lowerBound
        let key = head[head.startIndex..<tagEnd]
            .split(whereSeparator: { $0 == " " || $0 == "/" })
            .first?.lowercased() ?? ""
        // I contatori partono da zero: `0 of 3000` è la prima riga di 3000.
        return MagickProgress(
            phase: phaseLabels[key] ?? "elaboro",
            fraction: min(1, (offset + 1) / extent)
        )
    }

    // MARK: - Esecuzione

    struct RunResult: Sendable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    @discardableResult
    static func run(
        _ location: MagickLocation,
        arguments: [String],
        cancellation: MagickCancellation? = nil,
        onProgress: (@Sendable (MagickProgress) -> Void)? = nil
    ) throws -> RunResult {
        try run(
            location.executable,
            arguments: arguments,
            environment: location.environment,
            cancellation: cancellation,
            onProgress: onProgress
        )
    }

    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        cancellation: MagickCancellation? = nil,
        onProgress: (@Sendable (MagickProgress) -> Void)? = nil
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        if let cancellation, !cancellation.register(process) {
            throw MagickError(message: "Operazione annullata.")
        }
        defer { cancellation?.unregister(process) }

        try process.run()

        if let onProgress {
            return followProgress(process, stdout: outPipe, stderr: errPipe, onProgress: onProgress)
        }

        // Leggi in parallelo all'esecuzione: evita il deadlock sui pipe pieni.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outData),
            standardError: String(decoding: errData)
        )
    }

    /// Consuma lo stderr riga per riga mentre `magick` lavora, riportando
    /// l'avanzamento e tenendo da parte solo le righe che non lo sono: con
    /// `-monitor` un errore vero finisce in mezzo a migliaia di aggiornamenti.
    private static func followProgress(
        _ process: Process,
        stdout: Pipe,
        stderr: Pipe,
        onProgress: @Sendable (MagickProgress) -> Void
    ) -> RunResult {
        // Lo stdout va svuotato comunque: un pipe pieno bloccherebbe `magick`.
        let collected = DataBox()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            collected.value = stdout.fileHandleForReading.readDataToEndOfFile()
        }

        let handle = stderr.fileHandleForReading
        var pending = Data()
        var message = ""
        var lastFraction = -1.0

        func consume(_ line: String) {
            if let progress = parseMonitorLine(line) {
                // Una riga per riga di pixel: aggiornare la UI a ogni riga
                // significherebbe migliaia di refresh per immagine.
                guard abs(progress.fraction - lastFraction) >= 0.01 else { return }
                lastFraction = progress.fraction
                onProgress(progress)
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                message += line + "\n"
            }
        }

        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            // `-monitor` riscrive la stessa riga con un ritorno a capo singolo.
            // Il taglio avviene sui byte perché un chunk può spezzare un UTF-8
            // a metà, e decodificarlo così perderebbe l'intero pezzo.
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                consume(String(decoding: Data(pending[pending.startIndex..<end])))
                pending = Data(pending[pending.index(after: end)...])
            }
        }
        consume(String(decoding: pending))

        group.wait()
        process.waitUntilExit()

        return RunResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: collected.value),
            standardError: message
        )
    }

    /// Converte un file e restituisce l'URL prodotto.
    static func convert(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        using location: MagickLocation,
        preview: PreviewQuality? = nil,
        cancellation: MagickCancellation? = nil,
        onProgress: (@Sendable (MagickProgress) -> Void)? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // L'anteprima riscrive sempre lo stesso file temporaneo.
        let destination = settings.overwriteExisting || preview != nil
            ? output
            : uniqueURL(output)

        let args = arguments(
            settings: settings,
            input: input,
            output: destination,
            preview: preview,
            monitor: onProgress != nil
        )
        let result = try run(
            location,
            arguments: args,
            cancellation: cancellation,
            onProgress: onProgress
        )

        if cancellation?.cancelled == true {
            throw MagickError(message: "Operazione annullata.")
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MagickError(message: stderr.isEmpty ? "magick è terminato con codice \(result.exitCode)." : stderr)
        }
        return destination
    }
}

/// Scatola per passare dei byte tra il thread che legge lo stdout e chi aspetta.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private extension String {
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}
