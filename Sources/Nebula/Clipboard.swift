import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Clipboard as a conversion source

enum ClipboardSource {
    static let directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Nebula/Appunti", isDirectory: true)

    static func isTemporary(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    /// Copied files are used as they are; images and text are written to a temporary file.
    static func materialize() -> (urls: [URL], temporary: Bool)? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return (urls, false)
        }
        let types = pb.types ?? []
        guard let first = types.first else { return nil }

        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        func save(_ data: Data, _ name: String) -> (urls: [URL], temporary: Bool)? {
            let url = directory.appendingPathComponent(name)
            guard (try? data.write(to: url)) != nil else { return nil }
            return ([url], true)
        }

        let jpeg = NSPasteboard.PasteboardType("public.jpeg")
        let heic = NSPasteboard.PasteboardType("public.heic")
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, jpeg, heic]
        let hasText = pb.string(forType: .string)?.isEmpty == false
        if imageTypes.contains(first) || (!hasText && types.contains(where: { imageTypes.contains($0) })) {
            if let data = pb.data(forType: .png) { return save(data, "Immagine dagli appunti.png") }
            if let data = pb.data(forType: jpeg) { return save(data, "Immagine dagli appunti.jpg") }
            if let data = pb.data(forType: heic) { return save(data, "Immagine dagli appunti.heic") }
            if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return save(png, "Immagine dagli appunti.png")
            }
        }
        if let rtf = pb.data(forType: .rtf) { return save(rtf, "Testo dagli appunti.rtf") }
        if let html = pb.string(forType: .html) { return save(Data(html.utf8), "Testo dagli appunti.html") }
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let looksLikeMarkdown = text.contains("\n# ") || text.hasPrefix("# ") || text.contains("**") || text.contains("\n- ")
            return save(Data(text.utf8), looksLikeMarkdown ? "Testo dagli appunti.md" : "Testo dagli appunti.txt")
        }
        return nil
    }
}

// MARK: - Results back to the clipboard

enum ClipboardWriter {
    static func put(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard urls.count == 1, let url = urls.first else {
            pb.writeObjects(urls as [NSURL])
            return
        }
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        let ext = url.pathExtension.lowercased()
        if FileInspector.kind(of: url) == .image, let data = try? Data(contentsOf: url) {
            if let type = UTType(filenameExtension: ext) {
                item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
            }
            if let tiff = NSImage(data: data)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        if ["md", "txt", "html", "csv", "json"].contains(ext), let text = try? String(contentsOf: url, encoding: .utf8) {
            item.setString(text, forType: .string)
        }
        if ext == "rtf", let data = try? Data(contentsOf: url) { item.setData(data, forType: .rtf) }
        pb.writeObjects([item])
    }
}

// MARK: - Last copied items (⌥⌘V)

@MainActor
final class ClipboardHistory {
    struct Entry: Identifiable {
        let id = UUID()
        let items: [[NSPasteboard.PasteboardType: Data]]
        let label: String
        let symbol: String
        let thumbnail: NSImage?
        let signature: String
    }

    private(set) var entries: [Entry] = []
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    static let capacity = 3

    func start() {
        capture()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChange else { return }
        lastChange = count
        capture()
    }

    private func capture() {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        // Respect password managers & co.
        let concealed: [NSPasteboard.PasteboardType] = [.init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType")]
        if types.contains(where: { concealed.contains($0) }) { return }
        guard let pbItems = pb.pasteboardItems, !pbItems.isEmpty else { return }

        var snapshot: [[NSPasteboard.PasteboardType: Data]] = []
        var total = 0
        for item in pbItems {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    total += data.count
                    dict[type] = data
                }
            }
            snapshot.append(dict)
        }
        guard total < 40_000_000 else { return }

        let label: String, symbol: String, thumbnail: NSImage?, signature: String
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) file"
            symbol = "doc"
            thumbnail = NSWorkspace.shared.icon(forFile: urls[0].path)
            signature = "f:" + urls.map(\.path).joined(separator: "|")
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            label = Self.preview(text)
            symbol = "text.alignleft"
            thumbnail = nil
            signature = "t:" + String(text.prefix(400))
        } else if let image = NSImage(pasteboard: pb) {
            label = "Immagine"
            symbol = "photo"
            thumbnail = image
            signature = "i:\(total)"
        } else {
            return
        }

        entries.removeAll { $0.signature == signature }
        entries.insert(Entry(items: snapshot, label: label, symbol: symbol, thumbnail: thumbnail, signature: signature), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    private static func preview(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 26 ? String(flat.prefix(25)) + "…" : flat
    }

    /// Puts the entry back on the clipboard and pastes it into the front app.
    func paste(_ entry: Entry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items: [NSPasteboardItem] = entry.items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            Self.sendCommandV()
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
