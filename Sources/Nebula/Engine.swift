import Foundation

enum ConversionError: LocalizedError {
    case unsupported
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: tr("Conversione non supportata per questo file")
        case .failed(let message): tr(message)
        }
    }
}

typealias ProgressHandler = @Sendable (Double) -> Void

/// Dispatches a conversion to the right converter and reports overall progress.
enum ConversionEngine {
    static func run(_ target: ConversionTarget, on files: [URL], progress: @escaping ProgressHandler) async throws -> [URL] {
        if target.id == ConversionCatalog.mini.id {
            var outputs: [URL] = []
            let n = Double(files.count)
            for (i, file) in files.enumerated() {
                let base = Double(i)
                outputs.append(try await Miniaturizer.run(file) { p in progress((base + p) / n) })
            }
            return outputs
        }
        if target.combines {
            progress(0.35)
            let out = try await Archiver.zip(files)
            progress(1)
            return [out]
        }
        var outputs: [URL] = []
        let n = Double(files.count)
        for (i, file) in files.enumerated() {
            let base = Double(i)
            let out = try await convert(file, to: target) { p in
                progress((base + min(max(p, 0), 1)) / n)
            }
            outputs.append(out)
            progress((base + 1) / n)
        }
        return outputs
    }

    static func convert(_ src: URL, to t: ConversionTarget, progress: @escaping ProgressHandler) async throws -> URL {
        let kind = FileInspector.kind(of: src)
        if t.tag == "ai" {
            return try await MarkItDown.convert(src, progress: progress)
        }
        if t.needsFFmpeg || (kind.isMedia && !FileInspector.isNativeMedia(src)) {
            return try await FFmpeg.convert(src, to: t, progress: progress)
        }
        switch kind {
        case .image:
            return try ImageConverter.convert(src, to: t)
        case .video:
            return try await MediaConverter.convertVideo(src, to: t, progress: progress)
        case .audio:
            return try await MediaConverter.convertAudio(src, to: t, progress: progress)
        case .pdf:
            if t.ext == "png" || t.ext == "jpg" {
                return try PDFConverter.renderPages(src, to: t, progress: progress)
            }
            return try await MainActor.run { try PDFConverter.exportText(src, to: t) }
        case .richDocument, .markdown, .plainText:
            return try await MainActor.run { try DocumentConverter.convert(src, kind: kind, to: t) }
        case .json, .plist, .csv:
            return try DataConverter.convert(src, kind: kind, to: t)
        case .archive:
            return try await Archiver.extract(src)
        case .office, .folder, .other:
            throw ConversionError.unsupported
        }
    }
}

// MARK: - Output paths

enum OutputPath {
    /// Next to the original if writable, otherwise ~/Downloads.
    static func directory(for src: URL) -> URL {
        if ClipboardSource.isTemporary(src) {
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        }
        let dir = src.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func unique(in dir: URL, base: String, ext: String) -> URL {
        func make(_ name: String) -> URL {
            let url = dir.appendingPathComponent(name)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var url = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(n)")
            n += 1
        }
        return url
    }

    static func make(for src: URL, ext: String, suffix: String = "") -> URL {
        unique(in: directory(for: src), base: src.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    static func folder(for src: URL, suffix: String = "") throws -> URL {
        var base = src.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let url = unique(in: directory(for: src), base: base + suffix, ext: "")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Processes

enum ProcessRunner {
    static func run(_ process: Process, errorPipe: Pipe? = nil) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = errorPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let message = text.isEmpty ? "Processo terminato con codice \(proc.terminationStatus)" : String(text.suffix(280))
                    continuation.resume(throwing: ConversionError.failed(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum Archiver {
    static func zip(_ files: [URL]) async throws -> URL {
        let parent = files[0].deletingLastPathComponent().standardizedFileURL
        let sameParent = files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent }
        let out = files.count == 1
            ? OutputPath.unique(in: OutputPath.directory(for: files[0]), base: files[0].lastPathComponent, ext: "zip")
            : OutputPath.unique(in: OutputPath.directory(for: files[0]), base: tr("Archivio"), ext: "zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        if sameParent { process.currentDirectoryURL = parent }
        let names = files.map { sameParent ? "./" + $0.lastPathComponent : $0.path }
        process.arguments = ["-r", "-q", "-y", out.path] + names + ["-x", "*.DS_Store", "*/__MACOSX/*"]
        let err = Pipe()
        process.standardError = err
        try await ProcessRunner.run(process, errorPipe: err)
        return out
    }

    static func extract(_ src: URL) async throws -> URL {
        let dest = try OutputPath.folder(for: src)
        let process = Process()
        if src.pathExtension.lowercased() == "zip" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", src.path, dest.path]
        } else {
            // bsdtar (libarchive) handles tar, gz, bz2, xz, 7z, cpio, iso…
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", src.path, "-C", dest.path]
        }
        let err = Pipe()
        process.standardError = err
        do {
            try await ProcessRunner.run(process, errorPipe: err)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        return dest
    }
}
