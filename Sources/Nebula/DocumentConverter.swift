import AppKit

/// Rich text conversions through NSAttributedString (HTML import needs the main thread).
@MainActor
enum DocumentConverter {
    static func convert(_ src: URL, kind: FileKind, to t: ConversionTarget) throws -> URL {
        let out = OutputPath.make(for: src, ext: t.ext)
        if kind == .markdown {
            let html = Markdown.html(try readText(src), title: src.deletingPathExtension().lastPathComponent)
            if t.ext == "html" {
                try html.write(to: out, atomically: true, encoding: .utf8)
                return out
            }
            try write(try fromHTML(html), to: out, ext: t.ext)
            return out
        }
        try write(try load(src, kind: kind), to: out, ext: t.ext)
        return out
    }

    static func load(_ src: URL, kind: FileKind) throws -> NSAttributedString {
        if kind == .plainText {
            let font = src.pathExtension.lowercased() == "txt"
                ? NSFont.systemFont(ofSize: 12)
                : NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
            return NSAttributedString(string: try readText(src),
                                      attributes: [.font: font, .foregroundColor: NSColor.black])
        }
        return try NSAttributedString(url: src, options: [:], documentAttributes: nil)
    }

    static func readText(_ src: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: src, usedEncoding: &encoding) { return text }
        return try String(contentsOf: src, encoding: .isoLatin1)
    }

    static func fromHTML(_ html: String) throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8),
                               options: [.documentType: NSAttributedString.DocumentType.html,
                                         .characterEncoding: String.Encoding.utf8.rawValue],
                               documentAttributes: nil)
    }

    static func write(_ text: NSAttributedString, to out: URL, ext: String) throws {
        let type: NSAttributedString.DocumentType
        switch ext {
        case "pdf":
            try renderPDF(text, to: out)
            return
        case "txt":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
            return
        case "docx": type = .officeOpenXML
        case "rtf": type = .rtf
        case "html": type = .html
        case "odt": type = .openDocument
        case "doc": type = .docFormat
        default: throw ConversionError.unsupported
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: type])
        try data.write(to: out, options: .atomic)
    }

    /// Paginates the text on A4 by "printing" an off-screen text view to a PDF file.
    static func renderPDF(_ text: NSAttributedString, to out: URL) throws {
        let paper = NSSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = paper.width - 2 * margin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height - 2 * margin))
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.drawsBackground = false
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw ConversionError.failed("Creazione del PDF non riuscita") }
    }
}

// MARK: - Markdown → HTML (small, dependency-free)

enum Markdown {
    static func html(_ markdown: String, title: String) -> String {
        var out: [String] = []
        var paragraph: [String] = []
        var list: String?
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
                paragraph = []
            }
        }
        func closeList() {
            if let tag = list { out.append("</\(tag)>"); list = nil }
        }
        func openList(_ tag: String) {
            if list != tag { closeList(); out.append("<\(tag)>"); list = tag }
        }

        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flushParagraph(); closeList()
                out.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode { out.append(escape(line)); continue }
            if trimmed.isEmpty { flushParagraph(); closeList(); continue }

            if let h = heading(trimmed) {
                flushParagraph(); closeList()
                out.append("<h\(h.level)>\(inline(h.text))</h\(h.level)>")
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(); closeList()
                out.append("<hr>")
            } else if trimmed.hasPrefix(">") {
                flushParagraph(); closeList()
                out.append("<blockquote>\(inline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))</blockquote>")
            } else if let item = bullet(trimmed) {
                flushParagraph(); openList("ul")
                out.append("<li>\(inline(item))</li>")
            } else if let item = ordered(trimmed) {
                flushParagraph(); openList("ol")
                out.append("<li>\(inline(item))</li>")
            } else {
                closeList()
                paragraph.append(trimmed)
            }
        }
        flushParagraph(); closeList()
        if inCode { out.append("</code></pre>") }

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>
        body{font-family:-apple-system,"Helvetica Neue",sans-serif;font-size:15px;line-height:1.55;max-width:760px;margin:40px auto;padding:0 24px;color:#1d1d1f}
        h1,h2,h3{line-height:1.25}
        code{font-family:Menlo,monospace;font-size:13px;background:#f2f2f5;padding:1px 4px;border-radius:4px}
        pre{background:#f2f2f5;padding:12px 14px;border-radius:8px;overflow:auto}
        pre code{background:none;padding:0}
        blockquote{border-left:3px solid #d0d0d7;margin:0;padding-left:14px;color:#555}
        a{color:#0066cc}
        </style></head><body>
        \(out.joined(separator: "\n"))
        </body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ s: String) -> String {
        var r = escape(s)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*(.+?)\\*\\*", "<strong>$1</strong>"),
            ("__(.+?)__", "<strong>$1</strong>"),
            ("(?<!\\*)\\*(?!\\s)([^*]+?)\\*(?!\\*)", "<em>$1</em>"),
            ("(?<![\\w])_([^_]+)_(?![\\w])", "<em>$1</em>"),
            ("!\\[([^\\]]*)\\]\\(([^)]+)\\)", "<img alt=\"$1\" src=\"$2\">"),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>")
        ]
        for (pattern, template) in rules {
            r = r.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return r
    }

    private static func heading(_ s: String) -> (level: Int, text: String)? {
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(s.dropFirst(hashes + 1)))
    }

    private static func bullet(_ s: String) -> String? {
        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return String(s.dropFirst(2))
        }
        return nil
    }

    private static func ordered(_ s: String) -> String? {
        guard let range = s.range(of: "^\\d+[.)]\\s+", options: .regularExpression) else { return nil }
        return String(s[range.upperBound...])
    }
}
