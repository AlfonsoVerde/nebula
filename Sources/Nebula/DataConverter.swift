import Foundation

/// JSON ⇄ Property List, JSON ⇄ CSV, CSV → HTML table.
enum DataConverter {
    static func convert(_ src: URL, kind: FileKind, to t: ConversionTarget) throws -> URL {
        let data = try Data(contentsOf: src)
        let out = OutputPath.make(for: src, ext: t.ext)
        let result: Data

        switch (kind, t.ext) {
        case (.json, "plist"):
            let object = stripNulls(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
            guard object is [String: Any] || object is [Any] else {
                throw ConversionError.failed("Una property list deve contenere un oggetto o un array")
            }
            result = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)

        case (.json, "csv"):
            result = Data(try csvFromJSON(data).utf8)

        case (.plist, "json"):
            let object = try PropertyListSerialization.propertyList(from: data, format: nil)
            result = try JSONSerialization.data(withJSONObject: jsonSafe(object),
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])

        case (.csv, "json"):
            result = Data(jsonFromCSV(try text(data)).utf8)

        case (.csv, "html"):
            result = Data(htmlFromCSV(try text(data), title: src.deletingPathExtension().lastPathComponent).utf8)

        default:
            throw ConversionError.unsupported
        }
        try result.write(to: out, options: .atomic)
        return out
    }

    // MARK: CSV parsing

    private static func text(_ data: Data) throws -> String {
        guard var s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ConversionError.failed("Codifica del file non riconosciuta")
        }
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s
    }

    /// RFC 4180-ish parser; auto-detects `,` `;` or tab (Excel in Italian uses `;`).
    static func parseCSV(_ text: String) -> [[String]] {
        let header = text.prefix { !$0.isNewline }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { d in (d, header.filter { $0 == d }.count) }
        let delimiter = counts.max { $0.1 < $1.1 }?.0 ?? ","

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c.isNewline {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    private static func typed(_ value: String) -> Any {
        if let i = Int(value), String(i) == value { return i }
        if value.contains("."), !value.hasPrefix("0") || value.hasPrefix("0."), let d = Double(value) { return d }
        if value == "true" { return true }
        if value == "false" { return false }
        return value
    }

    private static func fragment(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "null"
    }

    /// Keeps the column order of the CSV (JSONSerialization would scramble keys).
    static func jsonFromCSV(_ text: String) -> String {
        let rows = parseCSV(text)
        guard let header = rows.first else { return "[]" }
        let body = Array(rows.dropFirst())
        var lines = ["["]
        for (r, row) in body.enumerated() {
            let fields = header.enumerated().map { c, key in
                "    \(fragment(key)): \(fragment(typed(c < row.count ? row[c] : "")))"
            }
            lines.append("  {\n" + fields.joined(separator: ",\n") + "\n  }" + (r < body.count - 1 ? "," : ""))
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    static func csvFromJSON(_ data: Data) throws -> String {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ConversionError.failed("Per il CSV serve un array JSON di oggetti")
        }
        var keys: [String] = []
        for object in array {
            for key in object.keys.sorted() where !keys.contains(key) { keys.append(key) }
        }
        func cell(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "" }
            if let s = value as? String { return s }
            if let n = value as? NSNumber {
                if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
                return n.stringValue
            }
            return fragment(value)
        }
        func escape(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : s
        }
        let lines = [keys.map(escape).joined(separator: ",")]
            + array.map { object in keys.map { escape(cell(object[$0])) }.joined(separator: ",") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func htmlFromCSV(_ text: String, title: String) -> String {
        let rows = parseCSV(text)
        let e = Markdown.escape
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(e(title))</title>
        <style>body{font-family:-apple-system,sans-serif;margin:32px;color:#1d1d1f}
        table{border-collapse:collapse;font-size:13px}th,td{padding:6px 12px;border-bottom:1px solid #e5e5ea;text-align:left}
        th{font-weight:600;border-bottom:2px solid #1d1d1f}tr:hover td{background:#f5f5f7}</style></head><body><table>
        """
        for (i, row) in rows.enumerated() {
            let tag = i == 0 ? "th" : "td"
            html += "<tr>" + row.map { "<\(tag)>\(e($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return html + "</table></body></html>"
    }

    // MARK: JSON / plist bridging

    static func stripNulls(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.compactMapValues { $0 is NSNull ? nil : stripNulls($0) }
        case let array as [Any]: return array.compactMap { $0 is NSNull ? nil : stripNulls($0) }
        default: return value
        }
    }

    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]: return dict.mapValues(jsonSafe)
        case let array as [Any]: return array.map(jsonSafe)
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let data as Data: return data.base64EncodedString()
        default: return value
        }
    }
}
