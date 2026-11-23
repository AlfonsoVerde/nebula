import AppKit
import AVFoundation
import Darwin
import ImageIO
import PDFKit

// MARK: - Expiry ("scade tra 1 / 7 / 30 giorni")

/// Files are followed by bookmark (they can be moved or renamed), get a Finder tag
/// with the date, and go to the Trash when they expire.
@MainActor
final class ExpiryStore {
    static let shared = ExpiryStore()

    private struct Record: Codable {
        var bookmark: Data
        var path: String
        var expires: Date
        var tag: String
    }

    private var records: [Record] = []
    private var timer: Timer?

    private static let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scadenze.json")
    }()

    private static let tagFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "d MMM"
        return f
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            records = saved
        }
    }

    func start() {
        sweep()
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweep() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.file, options: .atomic) }
    }

    private func resolve(_ record: Record) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: record.bookmark, bookmarkDataIsStale: &stale)
    }

    func hasExpiry(_ url: URL) -> Bool {
        records.contains { $0.path == url.standardizedFileURL.path || resolve($0)?.standardizedFileURL == url.standardizedFileURL }
    }

    func set(_ urls: [URL], days: Int) {
        remove(urls, persist: false)
        let expires = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        let tag = "⏳ scade il \(Self.tagFormatter.string(from: expires))"
        for url in urls {
            guard let bookmark = try? url.bookmarkData() else { continue }
            records.append(Record(bookmark: bookmark, path: url.standardizedFileURL.path, expires: expires, tag: tag))
            setTag(tag, on: url, adding: true)
        }
        save()
    }

    func remove(_ urls: [URL], persist: Bool = true) {
        let targets = Set(urls.map { $0.standardizedFileURL.path })
        records.removeAll { record in
            let current = resolve(record)?.standardizedFileURL.path ?? record.path
            guard targets.contains(current) || targets.contains(record.path) else { return false }
            if let url = resolve(record) { setTag(record.tag, on: url, adding: false) }
            return true
        }
        if persist { save() }
    }

    /// Expired files → Trash.
    func sweep() {
        let now = Date()
        var changed = false
        records.removeAll { record in
            guard record.expires <= now else { return false }
            if let url = resolve(record) {
                setTag(record.tag, on: url, adding: false)
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            changed = true
            return true
        }
        if changed { save() }
    }

    private func setTag(_ tag: String, on url: URL, adding: Bool) {
        let ns = url as NSURL
        var current: AnyObject?
        try? ns.getResourceValue(&current, forKey: .tagNamesKey)
        var tags = (current as? [String]) ?? []
        tags.removeAll { $0.hasPrefix("⏳ scade") }
        if adding { tags.append(tag) }
        try? ns.setResourceValue(tags, forKey: .tagNamesKey)
    }
}

// MARK: - Metadata cleaner

/// Removes GPS, camera/author info, document properties and download history,
/// in place. Originals are kept in a backup folder so ⌘Z can bring them back.
enum MetadataCleaner {
    static func clean(_ files: [URL], progress: @escaping ProgressHandler) async throws -> [(original: URL, backup: URL)] {
        let fm = FileManager.default
        let backupDir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula/Backup/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        var pairs: [(original: URL, backup: URL)] = []
        for (i, file) in files.enumerated() {
            let backup = backupDir.appendingPathComponent("\(i)-\(file.lastPathComponent)")
            try fm.copyItem(at: file, to: backup)
            pairs.append((file, backup))
            try await cleanOne(file)
            progress(Double(i + 1) / Double(files.count))
        }
        return pairs
    }

    private static func cleanOne(_ url: URL) async throws {
        let kind = FileInspector.kind(of: url)
        let ext = url.pathExtension.lowercased()
        switch kind {
        case .image: try image(url)
        case .pdf: try pdf(url)
        case .video, .audio: try? await media(url) // unsupported containers: attributes only
        default:
            if ["docx", "xlsx", "pptx"].contains(ext) { try await office(url) }
        }
        stripAttributes(url)
    }

    private static func temporary(next url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".nebula-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
    }

    private static func replace(_ url: URL, with tmp: URL) throws {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    /// Lossless copy of the image data with empty metadata (orientation kept).
    private static func image(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw ConversionError.failed("Immagine non leggibile")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = props?[kCGImagePropertyOrientation as String]

        let metadata = CGImageMetadataCreateMutable()
        if let orientation {
            _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, orientation as AnyObject)
        }
        let tmp = temporary(next: url)
        if let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, CGImageSourceGetCount(source), nil) {
            let options: [String: Any] = [
                kCGImageDestinationMetadata as String: metadata,
                kCGImageDestinationMergeMetadata as String: false,
                kCGImageMetadataShouldExcludeGPS as String: true,
                kCGImageMetadataShouldExcludeXMP as String: true
            ]
            if CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, nil) {
                try replace(url, with: tmp)
                return
            }
        }
        // Fallback: re-encode at high quality without metadata.
        try? FileManager.default.removeItem(at: tmp)
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw ConversionError.failed("Formato non supportato")
        }
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            var frameProps: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.95]
            if let orientation { frameProps[kCGImagePropertyOrientation as String] = orientation }
            CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Pulizia non riuscita") }
        try replace(url, with: tmp)
    }

    private static func pdf(_ url: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.failed("PDF non leggibile") }
        doc.documentAttributes = [:]
        let tmp = temporary(next: url)
        guard doc.write(to: tmp) else { throw ConversionError.failed("Pulizia del PDF non riuscita") }
        try replace(url, with: tmp)
    }

    private static func media(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let tmp = temporary(next: url)
        let type: AVFileType
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": type = .mp4
        case "m4a": type = .m4a
        case "mov", "qt": type = .mov
        default: return
        }
        session.outputURL = tmp
        session.outputFileType = type
        session.metadata = []
        session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            return
        }
        try replace(url, with: tmp)
    }

    /// Word / Excel / PowerPoint: blank author, company, dates, revision count, custom properties.
    private static func office(_ url: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("nebula-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, work.path]
        try await ProcessRunner.run(unzip)

        let props = work.appendingPathComponent("docProps", isDirectory: true)
        let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"/>
        """
        let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"/>
        """
        if fm.fileExists(atPath: props.appendingPathComponent("core.xml").path) {
            try core.write(to: props.appendingPathComponent("core.xml"), atomically: true, encoding: .utf8)
        }
        if fm.fileExists(atPath: props.appendingPathComponent("app.xml").path) {
            try app.write(to: props.appendingPathComponent("app.xml"), atomically: true, encoding: .utf8)
        }
        // custom.xml stays (it is listed in the package manifest) but is emptied.
        if fm.fileExists(atPath: props.appendingPathComponent("custom.xml").path) {
            let custom = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"/>
            """
            try custom.write(to: props.appendingPathComponent("custom.xml"), atomically: true, encoding: .utf8)
        }

        let tmp = temporary(next: url)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = work
        zip.arguments = ["-r", "-X", "-q", tmp.path, "."]
        try await ProcessRunner.run(zip)
        try replace(url, with: tmp)
    }

    /// Download origin, download date, Finder comment, last-used date.
    private static func stripAttributes(_ url: URL) {
        let names = ["com.apple.metadata:kMDItemWhereFroms", "com.apple.metadata:kMDItemDownloadedDate",
                     "com.apple.metadata:kMDItemFinderComment", "com.apple.lastuseddate#PS"]
        for name in names { removexattr(url.path, name, 0) }
    }
}
