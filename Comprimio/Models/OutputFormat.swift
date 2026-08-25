//
//  OutputFormat.swift
//  Comprimio
//

import Foundation

/// Famiglia del coder. Raggruppa alias e varianti che condividono le stesse
/// opzioni (tutti i JPEG hanno il progressivo, tutti i PNG il livello di
/// compressione…), così l'interfaccia non deve elencare i nomi uno per uno.
enum FormatFamily: String, Codable {
    case jpeg, png, webp, avif, heic, jxl, tiff, gif, other
}

/// Sezione del menu dei formati. Con oltre cento voci un elenco piatto è
/// inutilizzabile: le categorie sono l'unico modo per ritrovare un formato.
enum FormatCategory: String, CaseIterable, Identifiable, Codable {
    case common
    case variants
    case photo
    case graphics
    case document
    case icon
    case netpbm
    case rawSamples
    case scientific
    case text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .common: return "Web e uso comune"
        case .variants: return "Varianti"
        case .photo: return "Fotografia, HDR e cinema"
        case .graphics: return "Grafica ed editing"
        case .document: return "Documenti e vettoriali"
        case .icon: return "Icone e bitmap di sistema"
        case .netpbm: return "Netpbm e fax"
        case .rawSamples: return "Campioni grezzi"
        case .scientific: return "Scientifici e tecnici"
        case .text: return "Testo e braille"
        }
    }
}

/// Un formato di destinazione.
///
/// Non è un `enum` perché i formati sono più di cento: le proprietà stanno in
/// una tabella (`all`) e l'identità è la sola stringa `id`, che è anche ciò
/// che finisce nelle impostazioni salvate. Gli id dei formati storici sono
/// rimasti invariati, quindi le preferenze già memorizzate continuano a
/// risolversi.
struct OutputFormat: Identifiable, Hashable, Codable {

    /// Chiave stabile: persistita nelle impostazioni.
    let id: String
    let label: String
    /// Nome del coder per ImageMagick (`magick -list format`).
    /// `nil` solo per «Mantieni originale».
    let magickName: String?
    let fileExtension: String?
    let category: FormatCategory
    let family: FormatFamily
    let supportsQuality: Bool
    let supportsAlpha: Bool
    let supportsLossless: Bool
    /// Qualità massima utilizzabile con questo formato.
    let maxQuality: Int

    private init(
        _ id: String,
        _ label: String,
        magick: String?,
        ext: String?,
        _ category: FormatCategory,
        family: FormatFamily = .other,
        quality: Bool = false,
        alpha: Bool = false,
        lossless: Bool = false,
        maxQuality: Int = 100
    ) {
        self.id = id
        self.label = label
        self.magickName = magick
        self.fileExtension = ext
        self.category = category
        self.family = family
        self.supportsQuality = quality
        self.supportsAlpha = alpha
        self.supportsLossless = lossless
        self.maxQuality = maxQuality
    }

    static func == (lhs: OutputFormat, rhs: OutputFormat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // Nelle impostazioni viene salvato il solo id.
    init(from decoder: Decoder) throws {
        let id = try decoder.singleValueContainer().decode(String.self)
        self = OutputFormat.named(id) ?? .keepOriginal
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    // MARK: - Formati citati esplicitamente nel codice

    static let keepOriginal = OutputFormat(
        "keepOriginal", "Mantieni originale", magick: nil, ext: nil, .common)

    static let jpeg = OutputFormat(
        "jpeg", "JPEG", magick: "JPEG", ext: "jpg", .common, family: .jpeg, quality: true)

    static let png = OutputFormat(
        "png", "PNG", magick: "PNG", ext: "png", .common, family: .png, alpha: true)

    static let webp = OutputFormat(
        "webp", "WebP", magick: "WEBP", ext: "webp", .common,
        family: .webp, quality: true, alpha: true, lossless: true)

    // L'AVIF si ferma a 99: a 100 ImageMagick chiede a libheif la codifica
    // senza perdita e libaom la rifiuta («Only --enable_chroma_deltaq=0 can be
    // used with --lossless=1»). Nessun `-define` la aggira.
    static let avif = OutputFormat(
        "avif", "AVIF", magick: "AVIF", ext: "avif", .common,
        family: .avif, quality: true, alpha: true, maxQuality: 99)

    static let heic = OutputFormat(
        "heic", "HEIC", magick: "HEIC", ext: "heic", .common,
        family: .heic, quality: true, alpha: true)

    static let tiff = OutputFormat(
        "tiff", "TIFF", magick: "TIFF", ext: "tiff", .common,
        family: .tiff, quality: true, alpha: true)

    static let gif = OutputFormat(
        "gif", "GIF", magick: "GIF", ext: "gif", .common, family: .gif, alpha: true)

    static let bmp = OutputFormat(
        "bmp", "BMP", magick: "BMP", ext: "bmp", .common)

    // MARK: - Catalogo

    /// Tutti i formati scrivibili da ImageMagick che abbiano senso come file
    /// di destinazione. Restano fuori i pseudo-formati che non producono
    /// un'immagine (`INFO`, `JSON`, `HISTOGRAM`, `NULL`, `CLIP`…) e i
    /// contenitori video, che richiederebbero il delegate `ffmpeg`: non è nel
    /// bundle e il PATH dell'app è ristretto apposta.
    ///
    /// L'elenco è più ampio di quello che una singola installazione sa
    /// scrivere: JPEG XL, JPEG 2000 e OpenEXR dipendono da delegate opzionali.
    /// La disponibilità reale viene verificata a runtime contro
    /// `magick -list format`, quindi qui possono comparire senza rischio.
    ///
    /// Restano fuori anche i formati che `-list format` dichiara scrivibili ma
    /// che non lo sono per un'immagine raster: SVG, SVGZ e MVG vorrebbero il
    /// delegate `potrace` per vettorializzarla, APNG vuole `ffmpeg` e
    /// POCKETMOD vuole un font. Nessuno dei tre è nel bundle.
    ///
    /// Fuori anche il J2K, il codestream nudo del JPEG 2000: si scrive solo
    /// lasciando decidere all'estensione, e con il prefisso esplicito che
    /// `arguments(…)` antepone sempre (`J2K:file`) il coder non produce nulla.
    /// Il JPEG 2000 resta disponibile come JP2.
    static let all: [OutputFormat] = [
        keepOriginal,

        // Web e uso comune
        jpeg, png, webp, avif, heic,
        OutputFormat("heif", "HEIF", magick: "HEIF", ext: "heif", .common,
                     family: .heic, quality: true, alpha: true),
        OutputFormat("jxl", "JPEG XL", magick: "JXL", ext: "jxl", .common,
                     family: .jxl, quality: true, alpha: true, lossless: true),
        gif,
        tiff, bmp,

        // Varianti dei formati comuni
        OutputFormat("png8", "PNG a 8 bit (palette)", magick: "PNG8", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png24", "PNG a 24 bit", magick: "PNG24", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png32", "PNG a 32 bit (RGBA)", magick: "PNG32", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png48", "PNG a 48 bit", magick: "PNG48", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png64", "PNG a 64 bit (RGBA)", magick: "PNG64", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png00", "PNG (eredita profondità e tipo)", magick: "PNG00", ext: "png",
                     .variants, family: .png, alpha: true),
        OutputFormat("pjpeg", "JPEG progressivo", magick: "PJPEG", ext: "jpg", .variants,
                     family: .jpeg, quality: true),
        OutputFormat("bmp2", "BMP versione 2", magick: "BMP2", ext: "bmp", .variants),
        OutputFormat("bmp3", "BMP versione 3", magick: "BMP3", ext: "bmp", .variants),
        OutputFormat("gif87", "GIF 87a", magick: "GIF87", ext: "gif", .variants, family: .gif),
        OutputFormat("tiff64", "BigTIFF (TIFF a 64 bit)", magick: "TIFF64", ext: "tif", .variants,
                     family: .tiff, quality: true, alpha: true),
        OutputFormat("ptif", "TIFF piramidale", magick: "PTIF", ext: "ptif", .variants,
                     family: .tiff, quality: true, alpha: true),

        // Fotografia, HDR e cinema
        OutputFormat("jp2", "JPEG 2000", magick: "JP2", ext: "jp2", .photo,
                     quality: true, alpha: true),
        OutputFormat("pgx", "JPEG 2000 non compresso (PGX)", magick: "PGX", ext: "pgx", .photo),
        OutputFormat("exr", "OpenEXR", magick: "EXR", ext: "exr", .photo, alpha: true),
        OutputFormat("hdr", "Radiance HDR", magick: "HDR", ext: "hdr", .photo),
        OutputFormat("pfm", "Portable Float Map", magick: "PFM", ext: "pfm", .photo),
        OutputFormat("phm", "Portable Half Float Map", magick: "PHM", ext: "phm", .photo),
        OutputFormat("fl32", "FilmLight FL32", magick: "FL32", ext: "fl32", .photo),
        OutputFormat("dpx", "DPX (SMPTE 268M)", magick: "DPX", ext: "dpx", .photo),
        OutputFormat("cin", "Cineon", magick: "CIN", ext: "cin", .photo),
        OutputFormat("jps", "JPEG stereoscopico (JPS)", magick: "JPS", ext: "jps", .photo,
                     family: .jpeg, quality: true),
        OutputFormat("jng", "JNG (JPEG Network Graphics)", magick: "JNG", ext: "jng", .photo,
                     quality: true, alpha: true),
        OutputFormat("mng", "MNG (PNG multiplo)", magick: "MNG", ext: "mng", .photo, alpha: true),

        // Grafica ed editing
        OutputFormat("psd", "Photoshop (PSD)", magick: "PSD", ext: "psd", .graphics, alpha: true),
        OutputFormat("psb", "Photoshop grandi documenti (PSB)", magick: "PSB", ext: "psb",
                     .graphics, alpha: true),
        OutputFormat("miff", "MIFF (Magick Image File)", magick: "MIFF", ext: "miff", .graphics,
                     alpha: true),
        OutputFormat("mpc", "MPC (Magick Pixel Cache)", magick: "MPC", ext: "mpc", .graphics,
                     alpha: true),
        OutputFormat("vips", "VIPS", magick: "VIPS", ext: "v", .graphics, alpha: true),
        OutputFormat("tga", "Targa (TGA)", magick: "TGA", ext: "tga", .graphics, alpha: true),
        OutputFormat("pcx", "PCX (ZSoft Paintbrush)", magick: "PCX", ext: "pcx", .graphics),
        OutputFormat("dcx", "DCX (PCX multipagina)", magick: "DCX", ext: "dcx", .graphics),
        OutputFormat("dds", "DDS (DirectDraw Surface)", magick: "DDS", ext: "dds", .graphics,
                     quality: true, alpha: true),
        OutputFormat("dxt1", "DDS con compressione DXT1", magick: "DXT1", ext: "dds", .graphics),
        OutputFormat("dxt5", "DDS con compressione DXT5", magick: "DXT5", ext: "dds", .graphics,
                     alpha: true),
        OutputFormat("qoi", "QOI (Quite OK Image)", magick: "QOI", ext: "qoi", .graphics,
                     alpha: true),
        OutputFormat("farbfeld", "Farbfeld", magick: "FARBFELD", ext: "ff", .graphics, alpha: true),
        OutputFormat("sgi", "SGI (Irix RGB)", magick: "SGI", ext: "sgi", .graphics, alpha: true),
        OutputFormat("sun", "Sun Rasterfile", magick: "SUN", ext: "ras", .graphics),
        OutputFormat("pict", "PICT (QuickDraw)", magick: "PICT", ext: "pict", .graphics,
                     alpha: true),
        OutputFormat("wpg", "WordPerfect Graphics", magick: "WPG", ext: "wpg", .graphics),
        OutputFormat("palm", "Palm Pixmap", magick: "PALM", ext: "palm", .graphics, alpha: true),
        OutputFormat("pdb", "Palm Database (PDB)", magick: "PDB", ext: "pdb", .graphics),
        OutputFormat("ase", "Aseprite", magick: "ASE", ext: "ase", .graphics, alpha: true),
        OutputFormat("aai", "AAI Dune", magick: "AAI", ext: "aai", .graphics, alpha: true),
        OutputFormat("avs", "AVS X", magick: "AVS", ext: "avs", .graphics, alpha: true),
        OutputFormat("art", "PFS: 1st Publisher (ART)", magick: "ART", ext: "art", .graphics),
        OutputFormat("mat", "MATLAB (livello 5)", magick: "MAT", ext: "mat", .graphics,
                     alpha: true),
        OutputFormat("viff", "Khoros VIFF", magick: "VIFF", ext: "viff", .graphics, alpha: true),
        OutputFormat("xv", "Khoros XV", magick: "XV", ext: "xv", .graphics, alpha: true),
        OutputFormat("ipl", "IPL Image Sequence", magick: "IPL", ext: "ipl", .graphics,
                     alpha: true),
        OutputFormat("mtv", "MTV Raytracing", magick: "MTV", ext: "mtv", .graphics),
        OutputFormat("cals", "CALS Type 1", magick: "CALS", ext: "cals", .graphics),
        OutputFormat("hrz", "Slow Scan TeleVision (HRZ)", magick: "HRZ", ext: "hrz", .graphics),
        OutputFormat("sf3", "Simple File Format (SF3)", magick: "SF3", ext: "sf3", .graphics,
                     alpha: true),
        OutputFormat("rgf", "LEGO Mindstorms EV3 (RGF)", magick: "RGF", ext: "rgf", .graphics),
        OutputFormat("cip", "Cisco IP Phone", magick: "CIP", ext: "cip", .graphics),
        OutputFormat("otb", "On-the-air bitmap (OTB)", magick: "OTB", ext: "otb", .graphics),

        // Documenti e vettoriali
        OutputFormat("pdf", "PDF", magick: "PDF", ext: "pdf", .document,
                     quality: true, alpha: true),
        OutputFormat("pdfa", "PDF/A", magick: "PDFA", ext: "pdf", .document,
                     quality: true, alpha: true),
        OutputFormat("epdf", "PDF incapsulato (EPDF)", magick: "EPDF", ext: "epdf", .document,
                     quality: true),
        OutputFormat("ps", "PostScript", magick: "PS", ext: "ps", .document, quality: true),
        OutputFormat("ps2", "PostScript livello 2", magick: "PS2", ext: "ps", .document,
                     quality: true),
        OutputFormat("ps3", "PostScript livello 3", magick: "PS3", ext: "ps", .document,
                     quality: true),
        OutputFormat("eps", "EPS (PostScript incapsulato)", magick: "EPS", ext: "eps", .document,
                     quality: true),
        OutputFormat("eps2", "EPS livello 2", magick: "EPS2", ext: "eps", .document,
                     quality: true),
        OutputFormat("eps3", "EPS livello 3", magick: "EPS3", ext: "eps", .document,
                     quality: true),
        OutputFormat("epi", "EPS Interchange (EPI)", magick: "EPI", ext: "epi", .document,
                     quality: true),
        OutputFormat("ept", "EPS con anteprima TIFF", magick: "EPT", ext: "ept", .document,
                     quality: true),
        OutputFormat("ai", "Adobe Illustrator (AI)", magick: "AI", ext: "ai", .document,
                     quality: true),
        OutputFormat("pcl", "PCL (stampanti HP)", magick: "PCL", ext: "pcl", .document),

        // Icone e bitmap di sistema
        OutputFormat("ico", "ICO (icona Windows)", magick: "ICO", ext: "ico", .icon, alpha: true),
        OutputFormat("cur", "CUR (cursore Windows)", magick: "CUR", ext: "cur", .icon, alpha: true),
        OutputFormat("xbm", "X BitMap (XBM)", magick: "XBM", ext: "xbm", .icon),
        OutputFormat("xpm", "X PixMap (XPM)", magick: "XPM", ext: "xpm", .icon, alpha: true),
        OutputFormat("wbmp", "Wireless Bitmap (WBMP)", magick: "WBMP", ext: "wbmp", .icon),
        OutputFormat("picon", "Personal Icon (PICON)", magick: "PICON", ext: "picon", .icon,
                     alpha: true),

        // Netpbm e fax
        OutputFormat("pnm", "PNM (Portable Anymap)", magick: "PNM", ext: "pnm", .netpbm),
        OutputFormat("pbm", "PBM (bianco e nero)", magick: "PBM", ext: "pbm", .netpbm),
        OutputFormat("pgm", "PGM (scala di grigi)", magick: "PGM", ext: "pgm", .netpbm),
        OutputFormat("ppm", "PPM (colore)", magick: "PPM", ext: "ppm", .netpbm),
        OutputFormat("pam", "PAM", magick: "PAM", ext: "pam", .netpbm, alpha: true),
        OutputFormat("mono", "Bitmap bi-livello grezza", magick: "MONO", ext: "mono", .netpbm),
        OutputFormat("fax", "Fax Gruppo 3", magick: "FAX", ext: "fax", .netpbm),
        OutputFormat("g3", "Gruppo 3", magick: "G3", ext: "g3", .netpbm),
        OutputFormat("g4", "Gruppo 4", magick: "G4", ext: "g4", .netpbm),
        OutputFormat("group4", "CCITT Gruppo 4 grezzo", magick: "GROUP4", ext: "g4", .netpbm),
        OutputFormat("map", "Mappa colore (MAP)", magick: "MAP", ext: "map", .netpbm),

        // Campioni grezzi
        OutputFormat("rgb", "RGB grezzo", magick: "RGB", ext: "rgb", .rawSamples),
        OutputFormat("rgba", "RGBA grezzo", magick: "RGBA", ext: "rgba", .rawSamples, alpha: true),
        OutputFormat("rgbo", "RGBO grezzo (opacità)", magick: "RGBO", ext: "rgbo", .rawSamples,
                     alpha: true),
        OutputFormat("bgr", "BGR grezzo", magick: "BGR", ext: "bgr", .rawSamples),
        OutputFormat("bgra", "BGRA grezzo", magick: "BGRA", ext: "bgra", .rawSamples, alpha: true),
        OutputFormat("bgro", "BGRO grezzo (opacità)", magick: "BGRO", ext: "bgro", .rawSamples,
                     alpha: true),
        OutputFormat("cmyk", "CMYK grezzo", magick: "CMYK", ext: "cmyk", .rawSamples),
        OutputFormat("cmyka", "CMYKA grezzo", magick: "CMYKA", ext: "cmyka", .rawSamples,
                     alpha: true),
        OutputFormat("gray", "Grigio grezzo", magick: "GRAY", ext: "gray", .rawSamples),
        OutputFormat("graya", "Grigio con alfa grezzo", magick: "GRAYA", ext: "graya", .rawSamples,
                     alpha: true),
        OutputFormat("ycbcr", "YCbCr grezzo", magick: "YCBCR", ext: "ycbcr", .rawSamples),
        OutputFormat("ycbcra", "YCbCr con alfa grezzo", magick: "YCBCRA", ext: "ycbcra",
                     .rawSamples, alpha: true),
        OutputFormat("yuv", "YUV (CCIR 601)", magick: "YUV", ext: "yuv", .rawSamples),
        OutputFormat("uyvy", "UYVY interlacciato", magick: "UYVY", ext: "uyvy", .rawSamples),
        OutputFormat("pal", "PAL (YUV interlacciato a 16 bit)", magick: "PAL", ext: "pal",
                     .rawSamples),
        OutputFormat("bayer", "Mosaico Bayer", magick: "BAYER", ext: "bayer", .rawSamples),
        OutputFormat("bayera", "Mosaico Bayer con alfa", magick: "BAYERA", ext: "bayera",
                     .rawSamples, alpha: true),

        // Scientifici e tecnici
        OutputFormat("fits", "FITS (astronomia)", magick: "FITS", ext: "fits", .scientific),
        OutputFormat("vicar", "VICAR (NASA)", magick: "VICAR", ext: "vicar", .scientific),

        // Testo e braille
        OutputFormat("txt", "Testo (elenco dei pixel)", magick: "TXT", ext: "txt", .text,
                     alpha: true),
        OutputFormat("ftxt", "Testo formattato (FTXT)", magick: "FTXT", ext: "ftxt", .text,
                     alpha: true),
        OutputFormat("sixel", "SIXEL (grafica DEC)", magick: "SIXEL", ext: "sixel", .text),
        OutputFormat("brf", "Braille BRF", magick: "BRF", ext: "brf", .text),
        OutputFormat("isobrl", "Braille ISO 11548-1", magick: "ISOBRL", ext: "isobrl", .text),
        OutputFormat("isobrl6", "Braille ISO 11548-1 a 6 punti", magick: "ISOBRL6", ext: "isobrl6",
                     .text),
        OutputFormat("ubrl", "Braille Unicode", magick: "UBRL", ext: "ubrl", .text),
        OutputFormat("ubrl6", "Braille Unicode a 6 punti", magick: "UBRL6", ext: "ubrl6", .text)
    ]

    private static let byID: [String: OutputFormat] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func named(_ id: String) -> OutputFormat? { byID[id] }

    /// I formati di una categoria, «Mantieni originale» escluso: nel menu sta
    /// da solo, prima delle sezioni.
    static func formats(in category: FormatCategory) -> [OutputFormat] {
        all.filter { $0.category == category && $0 != .keepOriginal }
    }

    // MARK: - Risoluzione dall'estensione di partenza

    /// Estensione del file di partenza → formato di destinazione, per
    /// «Mantieni originale». La prima voce del catalogo che dichiara
    /// un'estensione vince, così `png` resta il PNG normale e non PNG24.
    private static let byExtension: [String: OutputFormat] = {
        var map: [String: OutputFormat] = [:]
        for format in all {
            guard let ext = format.fileExtension else { continue }
            if map[ext] == nil { map[ext] = format }
        }
        // Alias: estensioni diffuse che non coincidono con il nome del coder.
        map["jpeg"] = jpeg
        map["jpe"] = jpeg
        map["tif"] = tiff
        map["ff"] = named("farbfeld") ?? png
        map["ras"] = named("sun") ?? png
        map["sun"] = named("sun") ?? png
        map["pct"] = named("pict") ?? png
        map["tpic"] = named("tga") ?? png
        map["icb"] = named("tga") ?? png
        map["vda"] = named("tga") ?? png
        map["vst"] = named("tga") ?? png
        map["six"] = named("sixel") ?? png
        map["eps"] = named("eps") ?? png
        map["epsf"] = named("eps") ?? png
        map["epsi"] = named("eps") ?? png
        map["fts"] = named("fits") ?? png
        map["fit"] = named("fits") ?? png
        return map
    }()

    /// Formato effettivo per un file di input, risolvendo «Mantieni originale».
    ///
    /// Le estensioni che ImageMagick sa solo leggere (i raw delle fotocamere,
    /// XCF, DICOM…) non hanno un formato di destinazione corrispondente:
    /// ripiegano sul JPEG, che è la scelta naturale per uno scatto.
    static func resolved(_ format: OutputFormat, forInputExtension ext: String) -> OutputFormat {
        guard format == .keepOriginal else { return format }
        return byExtension[ext.lowercased()] ?? .jpeg
    }
}

enum ChromaSubsampling: String, CaseIterable, Identifiable, Codable {
    case auto, s444, s422, s420

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automatico"
        case .s444: return "4:4:4 (nessuno)"
        case .s422: return "4:2:2"
        case .s420: return "4:2:0"
        }
    }

    var magickValue: String? {
        switch self {
        case .auto: return nil
        case .s444: return "4:4:4"
        case .s422: return "4:2:2"
        case .s420: return "4:2:0"
        }
    }
}

enum ResizeMode: String, CaseIterable, Identifiable, Codable {
    case none, percent, fit, width, height, exact, fill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nessun ridimensionamento"
        case .percent: return "Percentuale"
        case .fit: return "Rientra in (larghezza × altezza)"
        case .width: return "Larghezza fissa"
        case .height: return "Altezza fissa"
        case .exact: return "Dimensione esatta (deforma)"
        case .fill: return "Riempi e ritaglia"
        }
    }
}

enum ResizeFilter: String, CaseIterable, Identifiable, Codable {
    case lanczos, mitchell, catrom, triangle, point

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanczos: return "Lanczos (nitido)"
        case .mitchell: return "Mitchell"
        case .catrom: return "Catrom"
        case .triangle: return "Triangle (morbido)"
        case .point: return "Point (nearest)"
        }
    }

    var magickValue: String {
        switch self {
        case .lanczos: return "Lanczos"
        case .mitchell: return "Mitchell"
        case .catrom: return "Catrom"
        case .triangle: return "Triangle"
        case .point: return "Point"
        }
    }
}

enum Rotation: String, CaseIterable, Identifiable, Codable {
    case none, cw90, ccw90, deg180

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Nessuna"
        case .cw90: return "90° orario"
        case .ccw90: return "90° antiorario"
        case .deg180: return "180°"
        }
    }

    var degrees: Int? {
        switch self {
        case .none: return nil
        case .cw90: return 90
        case .ccw90: return -90
        case .deg180: return 180
        }
    }
}

enum DestinationMode: String, CaseIterable, Identifiable, Codable {
    case subfolder, sameFolder, customFolder

    var id: String { rawValue }

    var label: String {
        switch self {
        case .subfolder: return "Sottocartella accanto all'originale"
        case .sameFolder: return "Stessa cartella dell'originale"
        case .customFolder: return "Cartella personalizzata"
        }
    }
}
