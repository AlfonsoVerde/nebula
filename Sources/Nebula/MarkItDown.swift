import AppKit
import PDFKit

/// "AI.md": documents → clean Markdown for LLMs.
/// Uses Microsoft MarkItDown (bundled at build time, or installed with pipx/brew);
/// falls back to a native PDFKit/NSAttributedString converter.
enum MarkItDown {
    static var executable: String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("markitdown/markitdown").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/markitdown", "/usr/local/bin/markitdown", "\(home)/.local/bin/markitdown"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { executable != nil }

    static func convert(_ src: URL, progress: @escaping ProgressHandler) async throws -> URL {
        let out = OutputPath.make(for: src, ext: "md", suffix: tr(" (AI)"))
        let kind = FileInspector.kind(of: src)

        if let exe = executable {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = [src.path, "-o", out.path]
            process.standardOutput = FileHandle.nullDevice
            let err = Pipe()
            process.standardError = err
            progress(0.15)
            do {
                try await ProcessRunner.run(process, errorPipe: err)
                if FileManager.default.fileExists(atPath: out.path) { return out }
            } catch {
                try? FileManager.default.removeItem(at: out)
                if kind == .office { throw error } // no native fallback for Office files
            }
        }

        let markdown = try await MainActor.run { try NativeMarkdown.convert(src, kind: kind) }
        try markdown.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

/// Native fallback: font sizes → headings, bold/italic/links → inline Markdown, lists → "- ".
@MainActor
enum NativeMarkdown {
    static func convert(_ src: URL, kind: FileKind) throws -> String {
        switch kind {
        case .pdf:
            guard let doc = PDFDocument(url: src) else { throw ConversionError.failed("File non leggibile") }
            var pages: [String] = []
            for i in 0..<doc.pageCount {
                if let text = doc.page(at: i)?.attributedString { pages.append(markdown(from: text)) }
            }
            return pages.joined(separator: "\n\n")
        case .richDocument:
            return markdown(from: try DocumentConverter.load(src, kind: kind))
        case .markdown:
            return try DocumentConverter.readText(src)
        case .plainText:
            let text = try DocumentConverter.readText(src)
            let ext = src.pathExtension.lowercased()
            // Source code / config → fenced block so models keep the formatting.
            return ext == "txt" || ext.isEmpty ? text : "```\(ext)\n\(text)\n```\n"
        case .json:
            return "```json\n\(try DocumentConverter.readText(src))\n```\n"
        case .plist:
            return "```xml\n\(try DocumentConverter.readText(src))\n```\n"
        case .csv:
            let rows = DataConverter.parseCSV(try DocumentConverter.readText(src))
            guard let header = rows.first else { return "" }
            func row(_ cells: [String]) -> String {
                "| " + header.indices.map { $0 < cells.count ? cells[$0].replacingOccurrences(of: "|", with: "\\|") : "" }
                    .joined(separator: " | ") + " |"
            }
            let lines = [row(header), "| " + header.map { _ in "---" }.joined(separator: " | ") + " |"] + rows.dropFirst().map(row)
            return lines.joined(separator: "\n") + "\n"
        default:
            throw ConversionError.failed("Per questo formato serve MarkItDown")
        }
    }

    static func markdown(from text: NSAttributedString) -> String {
        let full = NSRange(location: 0, length: text.length)
        let ns = text.string as NSString

        // Body size = the font size covering most characters.
        var weights: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: full) { value, range, _ in
            if let font = value as? NSFont { weights[(font.pointSize * 2).rounded() / 2, default: 0] += range.length }
        }
        let body = weights.max { $0.value < $1.value }?.key ?? 12

        var blocks: [String] = []
        ns.enumerateSubstrings(in: full, options: .byParagraphs) { substring, range, _, _ in
            guard let substring else { return }
            let plain = substring.trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty else { return }

            var maxSize: CGFloat = 0
            var allBold = true
            var isList = false
            text.enumerateAttributes(in: range) { attrs, _, _ in
                if let font = attrs[.font] as? NSFont {
                    maxSize = max(maxSize, font.pointSize)
                    if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
                }
                if let style = attrs[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty { isList = true }
            }

            let ratio = maxSize / max(body, 1)
            let bulletPrefixes = ["• ", "◦ ", "▪ ", "– ", "- ", "•\t", "◦\t"]
            if ratio >= 1.6 {
                blocks.append("# " + plain)
            } else if ratio >= 1.3 {
                blocks.append("## " + plain)
            } else if ratio >= 1.12 || (allBold && plain.count < 90 && !plain.hasSuffix(".")) {
                blocks.append("### " + plain)
            } else if let bullet = bulletPrefixes.first(where: { plain.hasPrefix($0) }) {
                blocks.append("- " + String(plain.dropFirst(bullet.count)))
            } else {
                let inline = inlineMarkdown(text.attributedSubstring(from: range))
                blocks.append(isList ? "- " + inline : inline)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func inlineMarkdown(_ text: NSAttributedString) -> String {
        var out = ""
        let ns = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let piece = ns.substring(with: range)
            let core = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { out += piece; return }
            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            var wrapped = core
            if traits.contains(.italic) { wrapped = "*\(wrapped)*" }
            if traits.contains(.bold) { wrapped = "**\(wrapped)**" }
            if let link = attrs[.link] {
                let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !target.isEmpty { wrapped = "[\(wrapped)](\(target))" }
            }
            let lead = String(piece.prefix(while: { $0 == " " }))
            let trail = String(piece.reversed().prefix(while: { $0 == " " }))
            out += lead + wrapped + trail
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
