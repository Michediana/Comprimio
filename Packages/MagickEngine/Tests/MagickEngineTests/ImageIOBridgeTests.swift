//
//  ImageIOBridgeTests.swift
//  MagickEngineTests
//
//  Il passaggio ImageIO per HEIC e raw. Senza file raw di prova la
//  decodifica raw si verifica solo con una foto vera, passata come
//
//      MAGICK_RAW_FIXTURE=/percorso/scatto.dng
//
//  (da xcodebuild con il prefisso TEST_RUNNER_). La codifica HEIC si salta
//  dove ImageIO non ha l'encoder, come in certi simulatori.
//

import CoreGraphics
import ImageIO
import MagickEngine
import UniformTypeIdentifiers
import XCTest

final class ImageIOBridgeTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testChoosesWhatPassesThroughImageIO() {
        for name in ["a.heic", "a.HEIC", "a.heif", "a.dng", "a.cr2", "a.nef", "a.arw"] {
            XCTAssertTrue(ImageIOBridge.decodesInput(URL(fileURLWithPath: name)), name)
        }
        for name in ["a.avif", "a.jpg", "a.png", "a.tiff", "a.webp", "a.jxl", "a"] {
            XCTAssertFalse(ImageIOBridge.decodesInput(URL(fileURLWithPath: name)), name)
        }
    }

    // MARK: - Decodifica

    /// Gli otto orientamenti EXIF: i pixel devono uscire come li mostra
    /// ImageIO stesso, e il tag deve tornare a 1, come fa libheif sul Mac.
    func testDecodeAppliesEveryOrientation() throws {
        for raw in UInt32(1)...8 {
            let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
            let input = try makeQuadrants(orientation: orientation)
            let output = directory.appendingPathComponent("o\(raw).tiff")

            try ImageIOBridge.decode(input, toTIFF: output)

            let expected = try reference(input)
            let decoded = try image(output)
            XCTAssertEqual(decoded.width, expected.width, "orientamento \(raw)")
            XCTAssertEqual(decoded.height, expected.height, "orientamento \(raw)")
            for (x, y) in quadrantCenters(width: decoded.width, height: decoded.height) {
                let got = try pixel(decoded, x, y), want = try pixel(expected, x, y)
                XCTAssertTrue(zip(got, want).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
                              "orientamento \(raw) in (\(x), \(y)): \(got) invece di \(want)")
            }
            XCTAssertEqual(try orientationTag(output), 1, "orientamento \(raw)")
        }
    }

    /// La profondità segue l'originale, come libheif con ImageMagick: 8 bit
    /// restano 8 (un PNG uscirebbe altrimenti a 16), oltre gli 8 si va a 16.
    func testDecodeKeepsDepth() throws {
        let shallow = try makeQuadrants(orientation: .right)
        let deep = try makeImage(bitsPerComponent: 16, type: .png)
        let shallowOut = directory.appendingPathComponent("8.tiff")
        let deepOut = directory.appendingPathComponent("16.tiff")

        try ImageIOBridge.decode(shallow, toTIFF: shallowOut)
        try ImageIOBridge.decode(deep, toTIFF: deepOut)

        XCTAssertEqual(try image(shallowOut).bitsPerComponent, 8)
        XCTAssertEqual(try image(deepOut).bitsPerComponent, 16)
    }

    func testDecodedTIFFFeedsImageMagick() throws {
        let input = try makeQuadrants(orientation: .left)
        let tiff = directory.appendingPathComponent("pass.tiff")
        let output = directory.appendingPathComponent("out.webp")

        try ImageIOBridge.decode(input, toTIFF: tiff)
        try LibraryEngine.run(arguments: [tiff.path, "-auto-orient", "-quality", "80", output.path])

        let result = try image(output)
        // 60×40 ruotato: l'orientamento è già nei pixel, -auto-orient non
        // deve girarlo una seconda volta.
        XCTAssertEqual(result.width, 40)
        XCTAssertEqual(result.height, 60)
    }

    /// Il TIFF porta l'EXIF come proprietà, che ImageMagick non riscrive:
    /// il JPEG 1×1 lo riattacca come profilo, senza toccare i colori.
    func testEXIFCarrierRestoresTheProfile() throws {
        let input = try makeQuadrants(orientation: .right)
        let tiff = directory.appendingPathComponent("exif.tiff")
        let carrier = directory.appendingPathComponent("carrier.jpg")
        let bare = directory.appendingPathComponent("bare.png")
        let tagged = directory.appendingPathComponent("tagged.png")

        try ImageIOBridge.decode(input, toTIFF: tiff)
        XCTAssertTrue(ImageIOBridge.writeEXIFCarrier(from: input, to: carrier))
        try LibraryEngine.run(arguments: [tiff.path, bare.path])
        try LibraryEngine.run(arguments: [tiff.path, "-profile", "JPEG:" + carrier.path, tagged.path])

        XCTAssertNil(try exif(bare))
        XCTAssertNotNil(try exif(tagged))
        XCTAssertNotEqual(try orientationTag(tagged), 6)
        let plain = try image(bare), restored = try image(tagged)
        for (x, y) in quadrantCenters(width: plain.width, height: plain.height) {
            XCTAssertEqual(try pixel(restored, x, y), try pixel(plain, x, y))
        }
    }

    func testDecodeRAWFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["MAGICK_RAW_FIXTURE"] else {
            throw XCTSkip("Nessuno scatto raw: imposta MAGICK_RAW_FIXTURE")
        }
        let output = directory.appendingPathComponent("raw.tiff")
        try ImageIOBridge.decode(URL(fileURLWithPath: path), toTIFF: output)
        let decoded = try image(output)
        XCTAssertEqual(decoded.bitsPerComponent, 16)
        print("RAW \(decoded.width)×\(decoded.height), \(decoded.colorSpace?.name as String? ?? "?")")
    }

    // MARK: - HEIC

    func testHEICRoundTrip() throws {
        guard ImageIOBridge.canEncodeHEIC else {
            throw XCTSkip("ImageIO non ha l'encoder HEIC su questo sistema")
        }
        let input = try makeQuadrants(orientation: .up)
        let tiff = directory.appendingPathComponent("from-magick.tiff")
        let heic = directory.appendingPathComponent("out.heic")
        let back = directory.appendingPathComponent("back.tiff")

        // Come farà l'app: ImageMagick fa il lavoro e scrive il TIFF…
        try LibraryEngine.run(arguments: [input.path, "-resize", "50%", "-compress", "None", tiff.path])
        // …ImageIO lo codifica.
        try ImageIOBridge.encodeHEIC(fromTIFF: tiff, to: heic, quality: 70)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(heic as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.heic.identifier)
        XCTAssertEqual(try image(heic).width, 30)
        XCTAssertEqual(try image(heic).height, 20)

        // E l'HEIC rientra dal passaggio inverso.
        try ImageIOBridge.decode(heic, toTIFF: back)
        XCTAssertEqual(try image(back).width, 30)
    }

    func testHEICQualityChangesSize() throws {
        guard ImageIOBridge.canEncodeHEIC else {
            throw XCTSkip("ImageIO non ha l'encoder HEIC su questo sistema")
        }
        let input = try makeImage(bitsPerComponent: 8, type: .tiff, width: 800, height: 600)
        let low = directory.appendingPathComponent("low.heic")
        let high = directory.appendingPathComponent("high.heic")

        try ImageIOBridge.encodeHEIC(fromTIFF: input, to: low, quality: 20)
        try ImageIOBridge.encodeHEIC(fromTIFF: input, to: high, quality: 95)

        XCTAssertLessThan(try fileSize(low), try fileSize(high))
    }

    /// Con `-auto-orient` spento i pixel restano com'erano e l'HEIC deve
    /// tenere il tag, come quello scritto da ImageMagick sul Mac; l'EXIF
    /// arriva dalla copia 1×1 scritta nello stesso comando.
    func testHEICTakesMetadataFromSidecar() throws {
        guard ImageIOBridge.canEncodeHEIC else {
            throw XCTSkip("ImageIO non ha l'encoder HEIC su questo sistema")
        }
        let input = try makeQuadrants(orientation: .right)
        let tiff = directory.appendingPathComponent("unrotated.tiff")
        let sidecar = directory.appendingPathComponent("sidecar.jpg")
        let heic = directory.appendingPathComponent("tagged.heic")

        try LibraryEngine.run(arguments: [
            input.path,
            "(", "+clone", "-sample", "1x1!", "-write", "JPEG:" + sidecar.path, "+delete", ")",
            "-compress", "None", "TIFF:" + tiff.path
        ])
        try ImageIOBridge.encodeHEIC(fromTIFF: tiff, to: heic, quality: 80, metadataFrom: sidecar)

        XCTAssertEqual(try image(heic).width, 60)
        XCTAssertEqual(try orientationTag(heic), 6)
        XCTAssertNotNil(try exif(heic))
    }

    // MARK: - Supporto

    /// Quattro quadranti di colori diversi, così ogni rotazione e ogni
    /// specchiatura dà un'immagine diversa. JPEG di qualità massima: tra
    /// un blocco e l'altro c'è un po' di rumore, al centro dei quadranti no.
    private func makeQuadrants(orientation: CGImagePropertyOrientation) throws -> URL {
        let width = 60, height = 40
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0)]
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(x: (index % 2) * width / 2, y: (index / 2) * height / 2,
                                width: width / 2, height: height / 2))
        }
        let url = directory.appendingPathComponent("q\(orientation.rawValue).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeImage(bitsPerComponent: Int, type: UTType,
                           width: Int = 64, height: Int = 48) throws -> URL {
        let deep = bitsPerComponent == 16
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)))
        let colors = [CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1),
                      CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: nil, colors: colors, locations: nil))
        context.drawLinearGradient(gradient, start: .zero,
                                   end: CGPoint(x: width, y: height), options: [])
        let url = directory.appendingPathComponent("g\(bitsPerComponent).\(type.preferredFilenameExtension ?? "img")")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Come ImageIO stesso mostra il file, orientamento compreso.
    private func reference(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 60
        ] as CFDictionary))
    }

    private func image(_ url: URL) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func orientationTag(_ url: URL) throws -> Int? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyOrientation] as? Int
    }

    private func exif(_ url: URL) throws -> [CFString: Any]? {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    private func quadrantCenters(width: Int, height: Int) -> [(Int, Int)] {
        [(width / 4, height / 4), (3 * width / 4, height / 4),
         (width / 4, 3 * height / 4), (3 * width / 4, 3 * height / 4)]
    }

    /// RGB a 8 bit del pixel (x, y), con l'origine in alto a sinistra.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1,
                                       width: image.width, height: image.height))
        return Array(data[0..<3])
    }
}
