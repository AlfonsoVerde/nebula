import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File kinds

enum FileKind: Sendable {
    case image, video, audio, pdf, richDocument, office, markdown, plainText, json, plist, csv, archive, folder, other

    var label: String {
        switch self {
        case .image: "Immagine"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .richDocument: "Documento"
        case .office: "Office"
        case .markdown: "Markdown"
        case .plainText: "Testo"
        case .json: "JSON"
        case .plist: "Property List"
        case .csv: "CSV"
        case .archive: "Archivio"
        case .folder: "Cartella"
        case .other: "File"
        }
    }

    var isMedia: Bool { self == .video || self == .audio }
}

enum FileInspector {
    private static let videoExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "3gp", "ogv", "vob"]
    private static let audioExtensions: Set<String> = ["flac", "ogg", "opus", "wma", "ape", "mka"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    private static let officeExtensions: Set<String> = ["pptx", "ppt", "xlsx", "xls", "epub", "msg"]

    private static let richTypes: [UTType] = [
        .rtf, .rtfd, .html, .webArchive,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text")
    ].compactMap { $0 }

    private static let archiveTypes: [UTType] = [.archive, .zip, .gzip, .bz2]

    /// Types AVFoundation can read natively.
    private static let avTypes: Set<String> = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    static func contentType(_ url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
    }

    static func kind(of url: URL) -> FileKind {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let ext = url.pathExtension.lowercased()

        if isDirectory.boolValue {
            return ext == "rtfd" ? .richDocument : .folder
        }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if markdownExtensions.contains(ext) { return .markdown }
        if officeExtensions.contains(ext) { return .office }
        if ext == "csv" { return .csv }

        guard let type = contentType(url) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) { return .video }
        if type.conforms(to: .json) { return .json }
        if type.conforms(to: .propertyList) { return .plist }
        if type.conforms(to: .commaSeparatedText) { return .csv }
        if richTypes.contains(where: { type.conforms(to: $0) }) { return .richDocument }
        if archiveTypes.contains(where: { type.conforms(to: $0) }) { return .archive }
        if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) || type.conforms(to: .text) { return .plainText }
        return .other
    }

    static func isNativeMedia(_ url: URL) -> Bool {
        guard let type = contentType(url) else { return false }
        return avTypes.contains(type.identifier)
    }
}

// MARK: - Targets

struct ConversionTarget: Identifiable, Hashable, Sendable {
    let id: String          // "image.png", "video.gif", …
    let label: String       // Shown on the planet
    let ext: String         // Output extension ("" for extraction)
    let symbol: String      // SF Symbol
    var suffix: String = "" // Appended to the output name, e.g. " HEVC"
    var combines = false    // One output for the whole selection (ZIP)
    var needsFFmpeg = false
    var needsMarkItDown = false
    var hue: Double = 0.7

    var tag: String { String(id.split(separator: ".").last ?? "") }

    var color: Color { Color(hue: hue, saturation: 0.72, brightness: 0.96) }
    var light: Color { Color(hue: hue, saturation: 0.28, brightness: 1) }
    var dark: Color { Color(hue: hue, saturation: 0.92, brightness: 0.30) }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ConversionCatalog {
    private static func t(_ id: String, _ label: String, _ ext: String, _ symbol: String,
                          suffix: String = "", ff: Bool = false) -> ConversionTarget {
        ConversionTarget(id: id, label: label, ext: ext, symbol: symbol, suffix: suffix, needsFFmpeg: ff)
    }

    static let zip = ConversionTarget(id: "any.zip", label: "ZIP", ext: "zip", symbol: "doc.zipper", combines: true)

    /// Center of the nebula: make the file smaller, keeping its format when possible.
    static let mini = ConversionTarget(id: "any.mini", label: "Mini", ext: "", symbol: "arrow.down.right.and.arrow.up.left", suffix: " (mini)")

    private static let ai = ConversionTarget(id: "doc.ai", label: "AI.md", ext: "md", symbol: "sparkles", suffix: " (AI)")

    private static func options(for kind: FileKind) -> [ConversionTarget] {
        switch kind {
        case .image:
            return [
                t("image.png", "PNG", "png", "photo"),
                t("image.jpg", "JPEG", "jpg", "photo.fill"),
                t("image.heic", "HEIC", "heic", "camera.aperture"),
                t("image.webp", "WebP", "webp", "globe", ff: !ImageConverter.canWriteWebP),
                t("image.tiff", "TIFF", "tiff", "square.stack.3d.up"),
                t("image.gif", "GIF", "gif", "play.square.stack"),
                t("image.bmp", "BMP", "bmp", "square.grid.3x3.fill"),
                t("image.pdf", "PDF", "pdf", "doc.richtext")
            ]
        case .video:
            return [
                t("video.mp4", "MP4", "mp4", "film"),
                t("video.mov", "MOV", "mov", "video"),
                t("video.hevc", "HEVC", "mov", "film.stack", suffix: " HEVC"),
                t("video.gif", "GIF", "gif", "play.square.stack"),
                t("video.m4a", "M4A", "m4a", "waveform"),
                t("video.png", "Frame", "png", "photo.on.rectangle", suffix: " frame"),
                t("video.webm", "WebM", "webm", "globe", ff: true),
                t("video.mkv", "MKV", "mkv", "shippingbox", ff: true),
                t("video.mp3", "MP3", "mp3", "music.note", ff: true)
            ]
        case .audio:
            return [
                t("audio.m4a", "M4A", "m4a", "waveform"),
                t("audio.wav", "WAV", "wav", "waveform.path"),
                t("audio.aiff", "AIFF", "aiff", "hifispeaker"),
                t("audio.caf", "CAF", "caf", "waveform.circle"),
                t("audio.mp3", "MP3", "mp3", "music.note", ff: true),
                t("audio.flac", "FLAC", "flac", "music.quarternote.3", ff: true),
                t("audio.ogg", "OGG", "ogg", "music.note.list", ff: true)
            ]
        case .pdf:
            return [
                ai,
                t("pdf.png", "PNG", "png", "photo"),
                t("pdf.jpg", "JPEG", "jpg", "photo.fill"),
                t("pdf.txt", "TXT", "txt", "text.alignleft"),
                t("pdf.docx", "DOCX", "docx", "doc.text.fill"),
                t("pdf.rtf", "RTF", "rtf", "doc.text"),
                t("pdf.html", "HTML", "html", "chevron.left.forwardslash.chevron.right")
            ]
        case .richDocument:
            return [
                ai,
                t("doc.pdf", "PDF", "pdf", "doc.richtext"),
                t("doc.docx", "DOCX", "docx", "doc.text.fill"),
                t("doc.rtf", "RTF", "rtf", "doc.text"),
                t("doc.html", "HTML", "html", "chevron.left.forwardslash.chevron.right"),
                t("doc.odt", "ODT", "odt", "doc.plaintext"),
                t("doc.doc", "DOC", "doc", "doc"),
                t("doc.txt", "TXT", "txt", "text.alignleft")
            ]
        case .office:
            var office = ai
            office.needsMarkItDown = true
            return [office]
        case .markdown:
            return [
                t("md.html", "HTML", "html", "chevron.left.forwardslash.chevron.right"),
                t("md.pdf", "PDF", "pdf", "doc.richtext"),
                t("md.docx", "DOCX", "docx", "doc.text.fill"),
                t("md.rtf", "RTF", "rtf", "doc.text"),
                t("md.txt", "TXT", "txt", "text.alignleft")
            ]
        case .plainText:
            return [
                t("text.pdf", "PDF", "pdf", "doc.richtext"),
                t("text.docx", "DOCX", "docx", "doc.text.fill"),
                t("text.rtf", "RTF", "rtf", "doc.text"),
                t("text.html", "HTML", "html", "chevron.left.forwardslash.chevron.right")
            ]
        case .json:
            return [
                t("json.plist", "PLIST", "plist", "list.bullet.indent"),
                t("json.csv", "CSV", "csv", "tablecells")
            ]
        case .plist:
            return [t("plist.json", "JSON", "json", "curlybraces")]
        case .csv:
            return [
                t("csv.json", "JSON", "json", "curlybraces"),
                t("csv.html", "HTML", "html", "tablecells")
            ]
        case .archive:
            return [t("archive.extract", "Estrai", "", "shippingbox.and.arrow.backward")]
        case .folder, .other:
            return []
        }
    }

    private static let equivalent: [String: String] = [
        "jpeg": "jpg", "tif": "tiff", "htm": "html", "aif": "aiff", "aifc": "aiff",
        "qt": "mov", "m4v": "mp4", "markdown": "md"
    ]

    private static func normalized(_ ext: String) -> String {
        let e = ext.lowercased()
        return equivalent[e] ?? e
    }

    private static func targets(for url: URL) -> [ConversionTarget] {
        let kind = FileInspector.kind(of: url)
        let sourceExt = normalized(url.pathExtension)
        var list = options(for: kind).filter { !($0.suffix.isEmpty && normalized($0.ext) == sourceExt) }
        if kind.isMedia && !FileInspector.isNativeMedia(url) {
            list = list.map { var t = $0; t.needsFFmpeg = true; return t }
        }
        return list
    }

    /// Targets offered for the whole selection: the intersection of what every
    /// file supports, plus ZIP which always works. Hues are spread along a
    /// cyan → violet → pink "galaxy" gradient.
    static func targets(for urls: [URL]) -> [ConversionTarget] {
        var common = urls.first.map(targets(for:)) ?? []
        for url in urls.dropFirst() {
            let ids = Set(targets(for: url).map(\.id))
            common = common.filter { ids.contains($0.id) }
        }
        common = common.filter { (!$0.needsFFmpeg || FFmpeg.path != nil) && (!$0.needsMarkItDown || MarkItDown.isAvailable) }
        var result = Array(common.prefix(9)) + [zip]
        let n = Double(max(result.count - 1, 1))
        for i in result.indices {
            result[i].hue = (0.50 + 0.47 * Double(i) / n).truncatingRemainder(dividingBy: 1)
        }
        return result
    }
}
