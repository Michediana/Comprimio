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
    /// `previewFit` limita l'anteprima a un lato massimo in pixel.
    static func arguments(
        settings: ConversionSettings,
        input: URL,
        output: URL,
        previewFit: Int? = nil
    ) -> [String] {
        let format = settings.targetFormat(for: input)
        var args: [String] = [input.path]

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
        if settings.resizeMode != .none || previewFit != nil {
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
        if let fit = previewFit {
            args += ["-resize", "\(fit)x\(fit)>"]
        }

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

        switch format {
        case .jpeg:
            if s.jpegProgressive { args += ["-interlace", "Plane"] }
            if let sub = s.chromaSubsampling.magickValue { args += ["-sampling-factor", sub] }
        case .png:
            args += ["-define", "png:compression-level=\(s.pngCompressionLevel)"]
        case .webp:
            args += ["-define", "webp:method=\(s.webpMethod)"]
            if s.lossless { args += ["-define", "webp:lossless=true"] }
        case .avif:
            if s.lossless { args += ["-define", "heic:lossless=true"] }
        default:
            break
        }

        if format.supportsQuality {
            let usesQuality = !(s.lossless && format.supportsLossless)
            if usesQuality { args += ["-quality", "\(Int(s.quality))"] }
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

    // MARK: - Esecuzione

    struct RunResult: Sendable {
        let exitCode: Int32
        let standardOutput: String
        let standardError: String
    }

    @discardableResult
    static func run(_ location: MagickLocation, arguments: [String]) throws -> RunResult {
        try run(location.executable, arguments: arguments, environment: location.environment)
    }

    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

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

    /// Converte un file e restituisce l'URL prodotto.
    static func convert(
        input: URL,
        output: URL,
        settings: ConversionSettings,
        using location: MagickLocation,
        previewFit: Int? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let destination = settings.overwriteExisting || previewFit != nil
            ? output
            : uniqueURL(output)

        let args = arguments(settings: settings, input: input, output: destination, previewFit: previewFit)
        let result = try run(location, arguments: args)

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let stderr = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MagickError(message: stderr.isEmpty ? "magick è terminato con codice \(result.exitCode)." : stderr)
        }
        return destination
    }
}

private extension String {
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}
