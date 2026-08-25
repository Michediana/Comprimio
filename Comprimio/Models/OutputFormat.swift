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
        case .common: return String(localized: "Web and everyday use")
        case .variants: return String(localized: "Variants")
        case .photo: return String(localized: "Photography, HDR and cinema")
        case .graphics: return String(localized: "Graphics and editing")
        case .document: return String(localized: "Documents and vector")
        case .icon: return String(localized: "Icons and system bitmaps")
        case .netpbm: return String(localized: "Netpbm and fax")
        case .rawSamples: return String(localized: "Raw samples")
        case .scientific: return String(localized: "Scientific and technical")
        case .text: return String(localized: "Text and braille")
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
    /// Etichetta in inglese, che è anche la chiave nel catalogo di stringhe.
    private let labelKey: String
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
        self.labelKey = label
        self.magickName = magick
        self.fileExtension = ext
        self.category = category
        self.family = family
        self.supportsQuality = quality
        self.supportsAlpha = alpha
        self.supportsLossless = lossless
        self.maxQuality = maxQuality
    }

    /// Nome mostrato nel menu dei formati.
    ///
    /// Gran parte delle etichette sono nomi propri («JPEG», «Khoros VIFF»):
    /// nel catalogo entrano solo quelle che contengono parole da tradurre, le
    /// altre non hanno una voce e ricadono sulla chiave, cioè su se stesse.
    var label: String {
        String(localized: String.LocalizationValue(labelKey))
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
        "keepOriginal", "Keep original", magick: nil, ext: nil, .common)

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

        // Web e uso comune. L'ordine è quello del menu: il JPEG XL sta
        // subito dopo il JPEG, di cui è il successore.
        jpeg,
        OutputFormat("jxl", "JPEG XL", magick: "JXL", ext: "jxl", .common,
                     family: .jxl, quality: true, alpha: true, lossless: true),
        png, webp, avif, heic,
        OutputFormat("heif", "HEIF", magick: "HEIF", ext: "heif", .common,
                     family: .heic, quality: true, alpha: true),
        gif,
        tiff, bmp,

        // Varianti dei formati comuni
        OutputFormat("png8", "8-bit PNG (palette)", magick: "PNG8", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png24", "24-bit PNG", magick: "PNG24", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png32", "32-bit PNG (RGBA)", magick: "PNG32", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png48", "48-bit PNG", magick: "PNG48", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png64", "64-bit PNG (RGBA)", magick: "PNG64", ext: "png", .variants,
                     family: .png, alpha: true),
        OutputFormat("png00", "PNG (inherits depth and type)", magick: "PNG00", ext: "png",
                     .variants, family: .png, alpha: true),
        OutputFormat("pjpeg", "Progressive JPEG", magick: "PJPEG", ext: "jpg", .variants,
                     family: .jpeg, quality: true),
        OutputFormat("bmp2", "BMP version 2", magick: "BMP2", ext: "bmp", .variants),
        OutputFormat("bmp3", "BMP version 3", magick: "BMP3", ext: "bmp", .variants),
        OutputFormat("gif87", "GIF 87a", magick: "GIF87", ext: "gif", .variants, family: .gif),
        OutputFormat("tiff64", "BigTIFF (64-bit TIFF)", magick: "TIFF64", ext: "tif", .variants,
                     family: .tiff, quality: true, alpha: true),
        OutputFormat("ptif", "Pyramidal TIFF", magick: "PTIF", ext: "ptif", .variants,
                     family: .tiff, quality: true, alpha: true),

        // Fotografia, HDR e cinema
        OutputFormat("jp2", "JPEG 2000", magick: "JP2", ext: "jp2", .photo,
                     quality: true, alpha: true),
        OutputFormat("pgx", "Uncompressed JPEG 2000 (PGX)", magick: "PGX", ext: "pgx", .photo),
        OutputFormat("exr", "OpenEXR", magick: "EXR", ext: "exr", .photo, alpha: true),
        OutputFormat("hdr", "Radiance HDR", magick: "HDR", ext: "hdr", .photo),
        OutputFormat("pfm", "Portable Float Map", magick: "PFM", ext: "pfm", .photo),
        OutputFormat("phm", "Portable Half Float Map", magick: "PHM", ext: "phm", .photo),
        OutputFormat("fl32", "FilmLight FL32", magick: "FL32", ext: "fl32", .photo),
        OutputFormat("dpx", "DPX (SMPTE 268M)", magick: "DPX", ext: "dpx", .photo),
        OutputFormat("cin", "Cineon", magick: "CIN", ext: "cin", .photo),
        OutputFormat("jps", "Stereoscopic JPEG (JPS)", magick: "JPS", ext: "jps", .photo,
                     family: .jpeg, quality: true),
        OutputFormat("jng", "JNG (JPEG Network Graphics)", magick: "JNG", ext: "jng", .photo,
                     quality: true, alpha: true),
        OutputFormat("mng", "MNG (multiple-image PNG)", magick: "MNG", ext: "mng", .photo, alpha: true),

        // Grafica ed editing
        OutputFormat("psd", "Photoshop (PSD)", magick: "PSD", ext: "psd", .graphics, alpha: true),
        OutputFormat("psb", "Photoshop Large Document (PSB)", magick: "PSB", ext: "psb",
                     .graphics, alpha: true),
        OutputFormat("miff", "MIFF (Magick Image File)", magick: "MIFF", ext: "miff", .graphics,
                     alpha: true),
        OutputFormat("mpc", "MPC (Magick Pixel Cache)", magick: "MPC", ext: "mpc", .graphics,
                     alpha: true),
        OutputFormat("vips", "VIPS", magick: "VIPS", ext: "v", .graphics, alpha: true),
        OutputFormat("tga", "Targa (TGA)", magick: "TGA", ext: "tga", .graphics, alpha: true),
        OutputFormat("pcx", "PCX (ZSoft Paintbrush)", magick: "PCX", ext: "pcx", .graphics),
        OutputFormat("dcx", "DCX (multi-page PCX)", magick: "DCX", ext: "dcx", .graphics),
        OutputFormat("dds", "DDS (DirectDraw Surface)", magick: "DDS", ext: "dds", .graphics,
                     quality: true, alpha: true),
        OutputFormat("dxt1", "DDS with DXT1 compression", magick: "DXT1", ext: "dds", .graphics),
        OutputFormat("dxt5", "DDS with DXT5 compression", magick: "DXT5", ext: "dds", .graphics,
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
        OutputFormat("mat", "MATLAB (level 5)", magick: "MAT", ext: "mat", .graphics,
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
        OutputFormat("ps2", "PostScript level 2", magick: "PS2", ext: "ps", .document,
                     quality: true),
        OutputFormat("ps3", "PostScript level 3", magick: "PS3", ext: "ps", .document,
                     quality: true),
        OutputFormat("eps", "EPS (PostScript incapsulato)", magick: "EPS", ext: "eps", .document,
                     quality: true),
        OutputFormat("eps2", "EPS level 2", magick: "EPS2", ext: "eps", .document,
                     quality: true),
        OutputFormat("eps3", "EPS level 3", magick: "EPS3", ext: "eps", .document,
                     quality: true),
        OutputFormat("epi", "EPS Interchange (EPI)", magick: "EPI", ext: "epi", .document,
                     quality: true),
        OutputFormat("ept", "EPS with TIFF preview", magick: "EPT", ext: "ept", .document,
                     quality: true),
        OutputFormat("ai", "Adobe Illustrator (AI)", magick: "AI", ext: "ai", .document,
                     quality: true),
        OutputFormat("pcl", "PCL (HP printers)", magick: "PCL", ext: "pcl", .document),

        // Icone e bitmap di sistema
        OutputFormat("ico", "ICO (Windows icon)", magick: "ICO", ext: "ico", .icon, alpha: true),
        OutputFormat("cur", "CUR (Windows cursor)", magick: "CUR", ext: "cur", .icon, alpha: true),
        OutputFormat("xbm", "X BitMap (XBM)", magick: "XBM", ext: "xbm", .icon),
        OutputFormat("xpm", "X PixMap (XPM)", magick: "XPM", ext: "xpm", .icon, alpha: true),
        OutputFormat("wbmp", "Wireless Bitmap (WBMP)", magick: "WBMP", ext: "wbmp", .icon),
        OutputFormat("picon", "Personal Icon (PICON)", magick: "PICON", ext: "picon", .icon,
                     alpha: true),

        // Netpbm e fax
        OutputFormat("pnm", "PNM (Portable Anymap)", magick: "PNM", ext: "pnm", .netpbm),
        OutputFormat("pbm", "PBM (black and white)", magick: "PBM", ext: "pbm", .netpbm),
        OutputFormat("pgm", "PGM (grayscale)", magick: "PGM", ext: "pgm", .netpbm),
        OutputFormat("ppm", "PPM (color)", magick: "PPM", ext: "ppm", .netpbm),
        OutputFormat("pam", "PAM", magick: "PAM", ext: "pam", .netpbm, alpha: true),
        OutputFormat("mono", "Raw bi-level bitmap", magick: "MONO", ext: "mono", .netpbm),
        OutputFormat("fax", "Group 3 fax", magick: "FAX", ext: "fax", .netpbm),
        OutputFormat("g3", "Group 3", magick: "G3", ext: "g3", .netpbm),
        OutputFormat("g4", "Group 4", magick: "G4", ext: "g4", .netpbm),
        OutputFormat("group4", "Raw CCITT Group 4", magick: "GROUP4", ext: "g4", .netpbm),
        OutputFormat("map", "Color map (MAP)", magick: "MAP", ext: "map", .netpbm),

        // Campioni grezzi
        OutputFormat("rgb", "Raw RGB", magick: "RGB", ext: "rgb", .rawSamples),
        OutputFormat("rgba", "Raw RGBA", magick: "RGBA", ext: "rgba", .rawSamples, alpha: true),
        OutputFormat("rgbo", "Raw RGBO (opacity)", magick: "RGBO", ext: "rgbo", .rawSamples,
                     alpha: true),
        OutputFormat("bgr", "Raw BGR", magick: "BGR", ext: "bgr", .rawSamples),
        OutputFormat("bgra", "Raw BGRA", magick: "BGRA", ext: "bgra", .rawSamples, alpha: true),
        OutputFormat("bgro", "Raw BGRO (opacity)", magick: "BGRO", ext: "bgro", .rawSamples,
                     alpha: true),
        OutputFormat("cmyk", "Raw CMYK", magick: "CMYK", ext: "cmyk", .rawSamples),
        OutputFormat("cmyka", "Raw CMYKA", magick: "CMYKA", ext: "cmyka", .rawSamples,
                     alpha: true),
        OutputFormat("gray", "Raw gray", magick: "GRAY", ext: "gray", .rawSamples),
        OutputFormat("graya", "Raw gray with alpha", magick: "GRAYA", ext: "graya", .rawSamples,
                     alpha: true),
        OutputFormat("ycbcr", "Raw YCbCr", magick: "YCBCR", ext: "ycbcr", .rawSamples),
        OutputFormat("ycbcra", "Raw YCbCr with alpha", magick: "YCBCRA", ext: "ycbcra",
                     .rawSamples, alpha: true),
        OutputFormat("yuv", "YUV (CCIR 601)", magick: "YUV", ext: "yuv", .rawSamples),
        OutputFormat("uyvy", "Interlaced UYVY", magick: "UYVY", ext: "uyvy", .rawSamples),
        OutputFormat("pal", "PAL (16-bit interlaced YUV)", magick: "PAL", ext: "pal",
                     .rawSamples),
        OutputFormat("bayer", "Bayer mosaic", magick: "BAYER", ext: "bayer", .rawSamples),
        OutputFormat("bayera", "Bayer mosaic with alpha", magick: "BAYERA", ext: "bayera",
                     .rawSamples, alpha: true),

        // Scientifici e tecnici
        OutputFormat("fits", "FITS (astronomy)", magick: "FITS", ext: "fits", .scientific),
        OutputFormat("vicar", "VICAR (NASA)", magick: "VICAR", ext: "vicar", .scientific),

        // Testo e braille
        OutputFormat("txt", "Text (pixel listing)", magick: "TXT", ext: "txt", .text,
                     alpha: true),
        OutputFormat("ftxt", "Formatted text (FTXT)", magick: "FTXT", ext: "ftxt", .text,
                     alpha: true),
        OutputFormat("sixel", "SIXEL (DEC graphics)", magick: "SIXEL", ext: "sixel", .text),
        OutputFormat("brf", "BRF braille", magick: "BRF", ext: "brf", .text),
        OutputFormat("isobrl", "ISO 11548-1 braille", magick: "ISOBRL", ext: "isobrl", .text),
        OutputFormat("isobrl6", "ISO 11548-1 six-dot braille", magick: "ISOBRL6", ext: "isobrl6",
                     .text),
        OutputFormat("ubrl", "Unicode braille", magick: "UBRL", ext: "ubrl", .text),
        OutputFormat("ubrl6", "Unicode six-dot braille", magick: "UBRL6", ext: "ubrl6", .text)
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
        case .auto: return String(localized: "Automatic")
        case .s444: return String(localized: "4:4:4 (none)")
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
        case .none: return String(localized: "No resizing")
        case .percent: return String(localized: "Percentage")
        case .fit: return String(localized: "Fit within (width × height)")
        case .width: return String(localized: "Fixed width")
        case .height: return String(localized: "Fixed height")
        case .exact: return String(localized: "Exact size (distorts)")
        case .fill: return String(localized: "Fill and crop")
        }
    }
}

enum ResizeFilter: String, CaseIterable, Identifiable, Codable {
    case lanczos, mitchell, catrom, triangle, point

    var id: String { rawValue }

    var label: String {
        switch self {
        case .lanczos: return String(localized: "Lanczos (sharp)")
        case .mitchell: return "Mitchell"
        case .catrom: return "Catrom"
        case .triangle: return String(localized: "Triangle (soft)")
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
        // Chiave esplicita: «nessuna rotazione» si accorda in modo diverso
        // da «nessuna filigrana».
        case .none: return String(localized: "rotation.none", defaultValue: "None")
        case .cw90: return String(localized: "90° clockwise")
        case .ccw90: return String(localized: "90° counterclockwise")
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
        case .subfolder: return String(localized: "Subfolder next to the original")
        case .sameFolder: return String(localized: "Same folder as the original")
        case .customFolder: return String(localized: "Custom folder")
        }
    }
}
