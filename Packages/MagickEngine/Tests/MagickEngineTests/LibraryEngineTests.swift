//
//  LibraryEngineTests.swift
//  MagickEngineTests
//
//  Si eseguono nel simulatore:
//
//      xcodebuild test -scheme MagickEngine \
//          -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
//
//  o su un dispositivo, aprendo Package.swift in Xcode (⌘U).
//
//  `testPeakMemoryOn48Megapixels` misura picco di memoria e tempo su una foto
//  da 48 MP. La prima esecuzione la genera e salta la misura; dalla seconda
//  in poi misura. Variabili facoltative (da xcodebuild con il prefisso
//  TEST_RUNNER_, che viene tolto; da Xcode nello schema, senza prefisso):
//
//      MAGICK_FIXTURE=/percorso/foto.jpg   un'altra foto (solo simulatore)
//      MAGICK_MEMORY_LIMIT_MB=256          limite delle risorse
//      MAGICK_ARGS="-resize 50%"           operazioni al posto di quelle di default
//      MAGICK_OUTPUT=out.png               nome, e quindi formato, dell'uscita
//

import CoreGraphics
import ImageIO
import MagickEngine
import UniformTypeIdentifiers
import XCTest

final class LibraryEngineTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Build

    func testVersionMatchesMac() {
        XCTAssertEqual(LibraryEngine.version, "7.1.2-30")
    }

    func testWritableFormats() {
        let formats = LibraryEngine.writableFormats
        for format in ["JPEG", "PNG", "WEBP", "GIF", "BMP", "PDF", "JNG", "PPM", "QOI",
                       "TIFF", "TIFF64", "PTIF", "JXL", "JP2", "EXR", "AVIF", "PSD"] {
            XCTAssertTrue(formats.contains(format), "\(format) non è scrivibile")
        }
        // HEIC e HEIF li scrive ImageIO: senza codec HEVC ImageMagick non può.
        XCTAssertFalse(formats.contains("HEIC"))
        print("Formati scrivibili: \(formats.count)")
    }

    /// I formati che dipendono dalle librerie della fase 2: si scrivono e si
    /// rileggono, così un delegate presente ma rotto non passa inosservato.
    func testRoundTripsThroughDelegateFormats() throws {
        let input = try makeJPEG(width: 320, height: 200)
        for ext in ["tiff", "jxl", "jp2", "exr", "avif"] {
            let output = directory.appendingPathComponent("out.\(ext)")
            let back = directory.appendingPathComponent("back-\(ext).png")
            try LibraryEngine.run(arguments: [input.path, "-quality", "80", output.path])
            try LibraryEngine.run(arguments: [output.path, back.path])
            let size = try XCTUnwrap(imageSize(back), ext)
            XCTAssertEqual(size, CGSize(width: 320, height: 200), ext)
        }
    }

    // MARK: - Conversione

    func testConvertsJPEGToWebP() throws {
        let input = try makeJPEG(width: 1200, height: 800)
        let output = directory.appendingPathComponent("out.webp")

        try LibraryEngine.run(arguments: [
            input.path, "-auto-orient", "-resize", "50%", "-quality", "80", output.path
        ])

        let size = try XCTUnwrap(imageSize(output))
        XCTAssertEqual(size.width, 600)
        XCTAssertEqual(size.height, 400)
        XCTAssertEqual(try type(of: output), UTType.webP.identifier)
    }

    func testReportsProgress() throws {
        let input = try makeJPEG(width: 2000, height: 1500)
        let output = directory.appendingPathComponent("out.png")
        let tags = Locked<[String]>([])

        try LibraryEngine.run(arguments: [input.path, "-resize", "50%", output.path]) { progress in
            XCTAssert((0...1).contains(progress.fraction))
            tags.mutate { if $0.last != progress.tag { $0.append(progress.tag) } }
        }

        let seen = tags.value
        XCTAssertTrue(seen.contains { $0.hasPrefix("Resize") }, "fasi viste: \(seen)")
        XCTAssertTrue(seen.contains { $0.hasPrefix("Save") }, "fasi viste: \(seen)")
    }

    func testCancellationStopsTheRun() throws {
        let input = try makeJPEG(width: 3000, height: 2000)
        let output = directory.appendingPathComponent("out.png")
        let cancellation = MagickCancellation()

        XCTAssertThrowsError(try LibraryEngine.run(
            arguments: [input.path, "-resize", "300%", "-blur", "0x8", output.path],
            cancellation: cancellation
        ) { _ in cancellation.cancel() }) { error in
            XCTAssertEqual((error as? MagickError)?.message, "Operation cancelled.")
        }
    }

    func testMissingInputThrowsMessage() {
        let missing = directory.appendingPathComponent("non-esiste.jpg")
        let output = directory.appendingPathComponent("out.png")

        XCTAssertThrowsError(try LibraryEngine.run(arguments: [missing.path, output.path])) { error in
            let message = (error as? MagickError)?.message ?? ""
            XCTAssertTrue(message.contains("non-esiste.jpg"), "messaggio: \(message)")
        }
    }

    /// Le corsie dell'app convertono più file in parallelo nello stesso
    /// processo: i messaggi e i monitor di una non devono finire nell'altra.
    func testParallelRunsAreIndependent() throws {
        let input = try makeJPEG(width: 1600, height: 1200)
        let missing = directory.appendingPathComponent("non-esiste.jpg")
        let results = Locked<[Int: String]>([:])

        DispatchQueue.concurrentPerform(iterations: 6) { lane in
            let output = directory.appendingPathComponent("out-\(lane).webp")
            let source = lane == 3 ? missing : input
            do {
                try LibraryEngine.run(arguments: [source.path, "-resize", "40%", output.path])
                results.mutate { $0[lane] = "ok" }
            } catch {
                results.mutate { $0[lane] = (error as? MagickError)?.message ?? "\(error)" }
            }
        }

        for lane in 0..<6 where lane != 3 {
            XCTAssertEqual(results.value[lane], "ok", "corsia \(lane)")
        }
        XCTAssertTrue(results.value[3]?.contains("non-esiste.jpg") == true)
    }

    // MARK: - Memoria

    func testPeakMemoryOn48Megapixels() throws {
        let path: String
        if let fixture = ProcessInfo.processInfo.environment["MAGICK_FIXTURE"] {
            path = fixture
        } else {
            // Sul dispositivo un percorso del Mac non esiste: la foto si genera
            // qui, ma in un'esecuzione a parte, perché generarla costa più
            // memoria di convertirla e coprirebbe la misura. Caches resta tra
            // un'esecuzione e l'altra.
            let cached = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("fixture-48mp.jpg")
            guard FileManager.default.fileExists(atPath: cached.path) else {
                try LibraryEngine.run(arguments: [
                    "-size", "8064x6048", "gradient:#d0603a-#2a5fb0",
                    "-attenuate", "0.6", "+noise", "Gaussian", "-quality", "90", cached.path
                ])
                throw XCTSkip("Foto di prova creata in \(cached.path): rilancia il test per la misura")
            }
            path = cached.path
        }
        if let limit = ProcessInfo.processInfo.environment["MAGICK_MEMORY_LIMIT_MB"].flatMap(UInt64.init) {
            LibraryEngine.setMemoryLimit(limit * 1024 * 1024)
        }
        // MAGICK_ARGS sostituisce le operazioni tra ingresso e uscita, per
        // misurare le fasi una alla volta; l'estensione di MAGICK_OUTPUT
        // sceglie il formato.
        let operations = ProcessInfo.processInfo.environment["MAGICK_ARGS"]
            .map { $0.split(separator: " ").map(String.init) }
            ?? ["-auto-orient", "-resize", "50%", "-quality", "82"]
        let output = directory.appendingPathComponent(
            ProcessInfo.processInfo.environment["MAGICK_OUTPUT"] ?? "out.webp")
        let before = Footprint.current

        // Con la QoS del thread del test lo scheduler lo tiene sui core a
        // efficienza e i tempi risultano 20–25 volte più lunghi (verificato
        // con `taskpolicy -b` sul Mac). L'app converte a `.userInitiated`.
        let start = Date()
        let phases = Locked<[(String, TimeInterval)]>([])
        let failure = Locked<Error?>(nil)
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            do {
                try LibraryEngine.run(arguments: [path] + operations + [output.path]) { progress in
                    phases.mutate { if $0.last?.0 != progress.tag { $0.append((progress.tag, Date().timeIntervalSince(start))) } }
                }
            } catch {
                failure.mutate { $0 = error }
            }
            done.signal()
        }
        worker.qualityOfService = .userInitiated
        worker.start()
        done.wait()
        if let error = failure.value { throw error }
        let elapsed = Date().timeIntervalSince(start)
        print("FASI " + phases.value.map { String(format: "%@ @%.2fs", $0.0, $0.1) }.joined(separator: ", "))

        print(String(
            format: "MISURA Q%d %@ → %@ (%d byte): picco %.0f MB (prima %.0f MB), %.2f s",
            LibraryEngine.quantumDepth,
            operations.joined(separator: " "),
            output.lastPathComponent,
            (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1,
            Double(Footprint.peak) / 1_048_576,
            Double(before) / 1_048_576,
            elapsed
        ))
    }

    // MARK: - Supporto

    private func makeJPEG(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let colors = [CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1),
                      CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: nil, colors: colors, locations: nil))
        context.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: width, y: height), options: [])
        let image = try XCTUnwrap(context.makeImage())

        let url = directory.appendingPathComponent("in-\(width)x\(height).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func imageSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    private func type(of url: URL) throws -> String? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return CGImageSourceGetType(source) as String?
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&storage)
        lock.unlock()
    }
}

/// Memoria del processo come la conta jetsam (`phys_footprint`).
private enum Footprint {
    private static func info() -> task_vm_info_data_t {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return info
    }

    static var current: UInt64 { info().phys_footprint }
    static var peak: UInt64 { UInt64(info().ledger_phys_footprint_peak) }
}
