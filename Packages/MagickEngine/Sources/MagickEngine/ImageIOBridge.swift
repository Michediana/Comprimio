//
//  ImageIOBridge.swift
//  MagickEngine
//
//  HEIC e raw delle fotocamere su iOS. Sul Mac li gestisce ImageMagick con
//  libheif + libde265 + x265 e con libraw; qui quelle librerie non ci sono
//  (GPL e LGPL, vedi docs/ROADMAP-iOS.md) e il lavoro passa a ImageIO:
//
//      HEIC/raw ──ImageIO──▶ TIFF senza perdita ──ImageMagick──▶ uscita
//      ingresso ──ImageMagick──▶ TIFF senza perdita ──ImageIO──▶ HEIC
//
//  Il TIFF intermedio riproduce ciò che ImageMagick leggerebbe sul Mac:
//  stessa profondità, stesso profilo colore, EXIF compreso, e l'orientamento
//  già applicato ai pixel, come fanno libheif e libraw.
//

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageIOBridge {

    // MARK: - Che cosa passa da qui

    /// `true` se il file va decodificato da ImageIO prima di passarlo a
    /// ImageMagick: HEIC/HEIF e raw delle fotocamere. L'AVIF no: lo legge
    /// ImageMagick con libheif e libaom, come sul Mac.
    public static func decodesInput(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        // L'SDK non ha una costante per l'AVIF, che per ImageIO è un HEIF.
        if type.identifier == "public.avif" || type.conforms(to: UTType("public.avif") ?? .data) {
            return false
        }
        return type.conforms(to: .heif) || type.conforms(to: .heic) || type.conforms(to: .rawImage)
    }

    /// Se questo sistema sa scrivere HEIC. Lo sanno tutti i dispositivi con
    /// iOS 17, ma il simulatore su certi Mac no: l'encoder è hardware.
    public static var canEncodeHEIC: Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }

    // MARK: - Decodifica

    /// Decodifica `source` (HEIC/HEIF o raw) in un TIFF senza perdita da
    /// passare a ImageMagick.
    ///
    /// Come sul Mac: profondità a 8 bit se l'originale ne ha 8 (libheif dà
    /// a ImageMagick la profondità del file), a 16 altrimenti; i raw sempre a
    /// 16 bit in sRGB, come libraw configurato da ImageMagick. L'orientamento
    /// è applicato ai pixel e il tag riportato a 1, quindi `-auto-orient`
    /// non ha più niente da fare, come con libheif.
    public static func decode(_ source: URL, toTIFF destination: URL) throws {
        try autoreleasepool {
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  CGImageSourceGetCount(imageSource) > 0 else {
                throw MagickError(message: String(localized: "The image could not be read."))
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
            let type = UTType(CGImageSourceGetType(imageSource) as String? ?? "")

            let image: CGImage
            if type?.conforms(to: .rawImage) == true {
                image = try decodeRAW(source)
            } else {
                guard let decoded = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    throw MagickError(message: String(localized: "The image could not be read."))
                }
                let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
                    .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
                image = try oriented(decoded, orientation)
            }
            try writeTIFF(image, metadata: properties, to: destination)
        }
    }

    /// I raw passano da Core Image, che applica il bilanciamento del bianco
    /// dello scatto e l'orientamento, come libraw con le impostazioni di
    /// ImageMagick.
    private static func decodeRAW(_ source: URL) throws -> CGImage {
        guard let filter = CIRAWFilter(imageURL: source), let output = filter.outputImage else {
            throw MagickError(message: String(localized: "The image could not be read."))
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // Niente cache: ogni file si decodifica una volta sola, e una foto da
        // 48 MP a 16 bit pesa 384 MB.
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])
        guard let image = context.createCGImage(output, from: output.extent,
                                                format: .RGBA16, colorSpace: space) else {
            throw MagickError(message: String(localized: "The image could not be read."))
        }
        return image
    }

    /// I pixel ruotati e specchiati secondo l'orientamento EXIF. Sono solo
    /// multipli di 90° e simmetrie: con l'interpolazione spenta ogni pixel
    /// finisce esattamente su un altro, senza ricampionamento.
    private static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> CGImage {
        if orientation == .up { return image }

        let width = image.width, height = image.height
        let swaps: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swaps = true
        default: swaps = false
        }
        let outWidth = swaps ? height : width
        let outHeight = swaps ? width : height

        let deep = image.bitsPerComponent > 8
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let alpha: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        let bitmapInfo = alpha.rawValue | (deep ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!

        guard let context = CGContext(
            data: nil, width: outWidth, height: outHeight,
            bitsPerComponent: deep ? 16 : 8, bytesPerRow: 0,
            space: space, bitmapInfo: bitmapInfo
        ) else {
            throw MagickError(message: String(localized: "The image could not be read."))
        }
        context.interpolationQuality = .none

        // Le trasformazioni dei tag EXIF 2…8, nel sistema di Core Graphics
        // (origine in basso a sinistra).
        let w = CGFloat(width), h = CGFloat(height)
        let transform: CGAffineTransform
        switch orientation {
        case .up:            transform = .identity
        case .upMirrored:    transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down:          transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored:  transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored:  transform = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right:         transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:          transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let result = context.makeImage() else {
            throw MagickError(message: String(localized: "The image could not be read."))
        }
        return result
    }

    /// TIFF non compresso: è un file di passaggio, e comprimerlo costerebbe
    /// tempo due volte. Il profilo colore arriva dal `CGImage`.
    private static func writeTIFF(_ image: CGImage, metadata: [CFString: Any], to destination: URL) throws {
        guard let output = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw MagickError(message: String(localized: "The image could not be saved."))
        }
        var properties: [CFString: Any] = [:]
        // EXIF, GPS e IPTC come nell'originale: è ciò che ImageMagick
        // conserva quando non c'è `-strip`.
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyDPIWidth,
                    kCGImagePropertyDPIHeight] {
            if let value = metadata[key] { properties[key] = value }
        }
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyTIFFDictionary] = [
            kCGImagePropertyTIFFCompression: 1,
            kCGImagePropertyTIFFOrientation: 1
        ]
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw MagickError(message: String(localized: "The image could not be saved."))
        }
    }

    // MARK: - Codifica HEIC

    /// Codifica in HEIC il TIFF prodotto da ImageMagick. `quality` va da 1
    /// a 100 come in `-quality`; `nil` lascia decidere a ImageIO.
    ///
    /// Orientamento e metadati sono quelli del TIFF: `-auto-orient` e
    /// `-strip` sono già stati applicati da ImageMagick. Il risultato non è
    /// lo stesso file del Mac (x265 contro l'encoder hardware), ma ha le
    /// stesse dimensioni, lo stesso profilo e gli stessi metadati.
    public static func encodeHEIC(fromTIFF source: URL, to destination: URL, quality: Int?) throws {
        guard canEncodeHEIC else {
            throw MagickError(message: String(localized: "This device cannot encode HEIC images."))
        }
        try autoreleasepool {
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                throw MagickError(message: String(localized: "The image could not be read."))
            }
            let metadata = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
            guard let output = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
                throw MagickError(message: String(localized: "The image could not be saved."))
            }
            var properties: [CFString: Any] = [:]
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyOrientation,
                        kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
                if let value = metadata[key] { properties[key] = value }
            }
            if let quality {
                properties[kCGImageDestinationLossyCompressionQuality] = Double(min(max(quality, 1), 100)) / 100
            }
            CGImageDestinationAddImage(output, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(output) else {
                throw MagickError(message: String(localized: "The image could not be saved."))
            }
        }
    }
}
