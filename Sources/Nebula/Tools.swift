import AppKit
import AVFoundation
import CoreImage
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Catalog

/// Pulsar (edit) and Buco nero (expire / clean) actions.
enum Tool: String {
    case mini, pdfMerge, pdfBlank, pdfLock
    case groupType, groupDate, renameSequence, renameDate, renameCustom
    case trim, mute
    case cutout, ocr, redact
    case expire1, expire7, expire30, unexpire, clean

    var label: String {
        switch self {
        case .mini: "Mini"
        case .pdfMerge: "Unisci"
        case .pdfBlank: "Svuota"
        case .pdfLock: "Password"
        case .groupType: "Per tipo"
        case .groupDate: "Per mese"
        case .renameSequence: "Numera"
        case .renameDate: "Per data"
        case .renameCustom: "Rinomina…"
        case .trim: "Taglia"
        case .mute: "Muto"
        case .cutout: "Scontorna"
        case .ocr: "Testo"
        case .redact: "Oscura"
        case .expire1: "1 giorno"
        case .expire7: "7 giorni"
        case .expire30: "30 giorni"
        case .unexpire: "Annulla scad."
        case .clean: "Pulisci"
        }
    }

    var symbol: String {
        switch self {
        case .mini: "arrow.down.right.and.arrow.up.left"
        case .pdfMerge: "doc.on.doc"
        case .pdfBlank: "eraser"
        case .pdfLock: "lock"
        case .groupType: "square.grid.2x2"
        case .groupDate: "calendar"
        case .renameSequence: "list.number"
        case .renameDate: "calendar.badge.clock"
        case .renameCustom: "character.cursor.ibeam"
        case .trim: "scissors"
        case .mute: "speaker.slash"
        case .cutout: "person.crop.rectangle"
        case .ocr: "text.viewfinder"
        case .redact: "eye.slash"
        case .expire1: "hourglass.bottomhalf.filled"
        case .expire7: "hourglass"
        case .expire30: "hourglass.tophalf.filled"
        case .unexpire: "hourglass.badge.plus"
        case .clean: "sparkles"
        }
    }

    /// Needs a small panel (password, name, trim handles) after the choice.
    var needsPanel: Bool { self == .pdfLock || self == .renameCustom || self == .trim }
}

enum ToolCatalog {
    static func pulsar(for urls: [URL]) -> [Tool] {
        let kinds = Set(urls.map(FileInspector.kind(of:)))
        let single = urls.count == 1
        var tools: [Tool] = []
        if kinds == [.pdf] {
            if single { tools += [.pdfBlank, .pdfLock] } else { tools.append(.pdfMerge) }
            tools.append(.mini)
        } else if kinds == [.folder] {
            tools = [.groupType, .groupDate, .renameSequence, .renameDate, .renameCustom]
        } else if kinds == [.video] && urls.allSatisfy(FileInspector.isNativeMedia) {
            if single { tools.append(.trim) }
            tools += [.mute, .mini]
        } else if kinds == [.audio] && urls.allSatisfy(FileInspector.isNativeMedia) {
            if single { tools.append(.trim) }
            tools.append(.mini)
        } else if kinds == [.image] {
            tools = [.cutout, .ocr, .redact, .mini]
        } else {
            tools = [.mini]
        }
        return tools
    }

    @MainActor
    static func blackHole(for urls: [URL]) -> [Tool] {
        var tools: [Tool] = [.expire1, .expire7, .expire30, .clean]
        if urls.contains(where: { ExpiryStore.shared.hasExpiry($0) }) { tools.append(.unexpire) }
        return tools
    }
}

struct ToolResult {
    var outputs: [URL] = []
    var undo: UndoCenter.Action?
    var message: String
}

// MARK: - Runner

enum ToolRunner {
    static func run(_ tool: Tool, on files: [URL], progress: @escaping ProgressHandler) async throws -> ToolResult {
        switch tool {
        case .mini:
            var outs: [URL] = []
            for (i, file) in files.enumerated() {
                outs.append(try await Miniaturizer.run(file) { p in progress((Double(i) + p) / Double(files.count)) })
            }
            return ToolResult(outputs: outs, undo: .files(outs, restoring: nil), message: "Ridotto")
        case .pdfMerge:
            let out = try mergePDFs(files)
            return ToolResult(outputs: [out], undo: .files([out], restoring: nil), message: "Uniti")
        case .pdfBlank:
            let out = try blankPDF(files[0])
            return ToolResult(outputs: [out], undo: .files([out], restoring: nil), message: "Svuotato")
        case .groupType, .groupDate:
            let (moves, created) = try group(files, byDate: tool == .groupDate)
            return ToolResult(undo: .moves(moves, created: created), message: "\(moves.count) spostati")
        case .renameSequence, .renameDate:
            let moves = try rename(files, base: nil, start: 1, byDate: tool == .renameDate)
            return ToolResult(undo: .moves(moves, created: []), message: "\(moves.count) rinominati")
        case .mute:
            var outs: [URL] = []
            for file in files { outs.append(try await mute(file)) }
            return ToolResult(outputs: outs, undo: .files(outs, restoring: nil), message: "Muto")
        case .cutout:
            var outs: [URL] = []
            for file in files { outs.append(try cutout(file)) }
            return ToolResult(outputs: outs, undo: .files(outs, restoring: nil), message: "Scontornato")
        case .redact:
            var outs: [URL] = []
            for file in files { outs.append(try redact(file)) }
            return ToolResult(outputs: outs, undo: .files(outs, restoring: nil), message: "Oscurato")
        case .ocr:
            let text = try files.map(recognizeText).joined(separator: "\n\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConversionError.failed("Nessun testo trovato nell'immagine")
            }
            let before = await MainActor.run { PasteboardSnapshot.capture() }
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return ToolResult(undo: .pasteboard(before), message: "Testo copiato")
        case .expire1, .expire7, .expire30:
            let days = tool == .expire1 ? 1 : (tool == .expire7 ? 7 : 30)
            await MainActor.run { ExpiryStore.shared.set(files, days: days) }
            return ToolResult(undo: .expiry(files), message: "Scade tra \(days) g")
        case .unexpire:
            await MainActor.run { ExpiryStore.shared.remove(files) }
            return ToolResult(message: "Scadenza tolta")
        case .clean:
            let pairs = try await MetadataCleaner.clean(files, progress: progress)
            return ToolResult(undo: .replaced(pairs), message: "Pulito")
        case .pdfLock, .renameCustom, .trim:
            throw ConversionError.failed("Serve il pannello")
        }
    }

    // MARK: PDF

    static func mergePDFs(_ files: [URL]) throws -> URL {
        let sorted = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let merged = PDFDocument()
        for file in sorted {
            guard let doc = PDFDocument(url: file) else { throw ConversionError.failed("\(file.lastPathComponent) non è leggibile") }
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i) { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = OutputPath.unique(in: OutputPath.directory(for: sorted[0]), base: "Unito", ext: "pdf")
        guard merged.write(to: out) else { throw ConversionError.failed("Impossibile scrivere il PDF unito") }
        return out
    }

    /// Clears what was typed into a fillable PDF form.
    static func blankPDF(_ file: URL) throws -> URL {
        guard let doc = PDFDocument(url: file) else { throw ConversionError.failed("PDF non leggibile") }
        var fields = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                fields += 1
                switch annotation.widgetFieldType {
                case .button: annotation.buttonWidgetState = .offState
                default: annotation.widgetStringValue = ""
                }
            }
        }
        guard fields > 0 else {
            throw ConversionError.failed("Questo PDF non ha campi compilabili da svuotare")
        }
        let out = OutputPath.make(for: file, ext: "pdf", suffix: " (vuoto)")
        guard doc.write(to: out) else { throw ConversionError.failed("Impossibile scrivere il PDF") }
        return out
    }

    static func lockPDF(_ file: URL, password: String) throws -> URL {
        guard let doc = PDFDocument(url: file) else { throw ConversionError.failed("PDF non leggibile") }
        let out = OutputPath.make(for: file, ext: "pdf", suffix: " (protetto)")
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard doc.write(to: out, withOptions: options) else { throw ConversionError.failed("Impossibile proteggere il PDF") }
        return out
    }

    // MARK: Folders

    private static func contents(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                                                    options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
    }

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private static func groupName(_ url: URL) -> String {
        switch FileInspector.kind(of: url) {
        case .image: "Immagini"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .richDocument, .office: "Documenti"
        case .markdown, .plainText: "Testi"
        case .json, .plist, .csv: "Dati"
        case .archive: "Archivi"
        case .folder, .other: "Altro"
        }
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "yyyy-MM LLLL"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Moves the files inside each folder into sub-folders (by type or by month).
    static func group(_ folders: [URL], byDate: Bool) throws -> ([(from: URL, to: URL)], [URL]) {
        let fm = FileManager.default
        var moves: [(from: URL, to: URL)] = []
        var created: [URL] = []
        for folder in folders {
            for file in try contents(of: folder) {
                let name = byDate ? monthFormatter.string(from: creationDate(file)).capitalized : groupName(file)
                let sub = folder.appendingPathComponent(name, isDirectory: true)
                if !fm.fileExists(atPath: sub.path) {
                    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    created.append(sub)
                }
                let target = OutputPath.unique(in: sub, base: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension)
                try fm.moveItem(at: file, to: target)
                moves.append((file, target))
            }
        }
        guard !moves.isEmpty else { throw ConversionError.failed("La cartella non contiene file da raggruppare") }
        return (moves, created)
    }

    /// "Nome 001.ext" (base = folder name by default) or "2026-11-23 001.ext".
    static func rename(_ folders: [URL], base: String?, start: Int, byDate: Bool) throws -> [(from: URL, to: URL)] {
        let fm = FileManager.default
        var moves: [(from: URL, to: URL)] = []
        for folder in folders {
            var files = try contents(of: folder)
            if byDate {
                files.sort { creationDate($0) < creationDate($1) }
            } else {
                files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            let digits = max(3, String(files.count + start).count)
            var counters: [String: Int] = [:]
            var plan: [(from: URL, to: URL)] = []
            for file in files {
                let prefix = byDate ? dayFormatter.string(from: creationDate(file)) : (base ?? folder.lastPathComponent)
                let n = counters[prefix, default: start]
                counters[prefix] = n + 1
                let number = String(format: "%0\(digits)d", n)
                var target = folder.appendingPathComponent("\(prefix) \(number)")
                if !file.pathExtension.isEmpty { target.appendPathExtension(file.pathExtension) }
                if target.lastPathComponent != file.lastPathComponent { plan.append((file, target)) }
            }
            // Two phases so names can swap without collisions.
            var temporary: [(from: URL, temp: URL, to: URL)] = []
            for step in plan {
                let temp = folder.appendingPathComponent(".nebula-\(UUID().uuidString)")
                try fm.moveItem(at: step.from, to: temp)
                temporary.append((step.from, temp, step.to))
            }
            for step in temporary {
                let final = fm.fileExists(atPath: step.to.path)
                    ? OutputPath.unique(in: folder, base: step.to.deletingPathExtension().lastPathComponent, ext: step.to.pathExtension)
                    : step.to
                try fm.moveItem(at: step.temp, to: final)
                moves.append((step.from, final))
            }
        }
        guard !moves.isEmpty else { throw ConversionError.failed("Niente da rinominare") }
        return moves
    }

    // MARK: Video & audio

    private static func fileType(for url: URL) -> (AVFileType, String) {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": (.mp4, "mp4")
        case "m4a": (.m4a, "m4a")
        default: (.mov, "mov")
        }
    }

    static func trim(_ file: URL, from start: Double, to end: Double, progress: @escaping ProgressHandler) async throws -> URL {
        let asset = AVURLAsset(url: file)
        let isAudio = FileInspector.kind(of: file) == .audio
        let preset = isAudio ? AVAssetExportPresetAppleM4A : AVAssetExportPresetPassthrough
        let (type, ext) = isAudio ? (AVFileType.m4a, "m4a") : fileType(for: file)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("Impossibile tagliare questo file")
        }
        let out = OutputPath.make(for: file, ext: ext, suffix: " (taglio)")
        session.outputURL = out
        session.outputFileType = type
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        end: CMTime(seconds: end, preferredTimescale: 600))
        let ticker = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        await session.export()
        ticker.cancel()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw session.error ?? ConversionError.failed("Taglio non riuscito")
        }
        return out
    }

    static func mute(_ file: URL) async throws -> URL {
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try copy?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            copy?.preferredTransform = try await track.load(.preferredTransform)
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.failed("Impossibile togliere l'audio")
        }
        let out = OutputPath.make(for: file, ext: "mov", suffix: " (muto)")
        session.outputURL = out
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            throw session.error ?? ConversionError.failed("Impossibile togliere l'audio")
        }
        return out
    }

    // MARK: Images (Vision)

    private static func orientedImage(_ file: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: file, options: [.applyOrientationProperty: true]) else {
            throw ConversionError.failed("Immagine non leggibile")
        }
        return image
    }

    private static func render(_ image: CIImage) throws -> CGImage {
        guard let cg = CIContext().createCGImage(image, from: image.extent) else {
            throw ConversionError.failed("Rendering dell'immagine non riuscito")
        }
        return cg
    }

    /// Subject cut-out → transparent PNG.
    static func cutout(_ file: URL) throws -> URL {
        let image = try orientedImage(file)
        let handler = VNImageRequestHandler(ciImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError.failed("Nessun soggetto riconosciuto")
        }
        let masked = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let out = OutputPath.make(for: file, ext: "png", suffix: " (scontornata)")
        try ImageConverter.write(try render(CIImage(cvPixelBuffer: masked)), to: out, uti: UTType.png.identifier)
        return out
    }

    static func recognizeText(_ file: URL) throws -> String {
        let handler = VNImageRequestHandler(ciImage: try orientedImage(file))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["it-IT", "en-US"]
        try handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Blurs and pixelates faces and plate-like text.
    static func redact(_ file: URL) throws -> URL {
        let image = try orientedImage(file)
        let handler = VNImageRequestHandler(ciImage: image)
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        try handler.perform([faces, text])

        var regions: [CGRect] = (faces.results ?? []).map { $0.boundingBox.insetBy(dx: -$0.boundingBox.width * 0.15, dy: -$0.boundingBox.height * 0.2) }
        for observation in text.results ?? [] {
            guard let candidate = observation.topCandidates(1).first?.string, looksLikePlate(candidate) else { continue }
            regions.append(observation.boundingBox.insetBy(dx: -observation.boundingBox.width * 0.1, dy: -observation.boundingBox.height * 0.35))
        }
        guard !regions.isEmpty else { throw ConversionError.failed("Nessun volto o targa trovati") }

        let extent = image.extent
        var output = image
        for normalized in regions {
            let rect = VNImageRectForNormalizedRect(normalized, Int(extent.width), Int(extent.height))
                .offsetBy(dx: extent.minX, dy: extent.minY)
                .intersection(extent)
            guard !rect.isNull, rect.width > 2, rect.height > 2 else { continue }
            let scale = max(8, max(rect.width, rect.height) / 10)
            let hidden = image.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(scale) / 2)
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale,
                                                            kCIInputCenterKey: CIVector(cgPoint: rect.origin)])
                .cropped(to: rect)
            output = hidden.composited(over: output)
        }
        var ext = file.pathExtension.lowercased()
        if !["jpg", "jpeg", "png", "heic", "tiff"].contains(ext) { ext = "jpg" }
        if ext == "jpeg" { ext = "jpg" }
        let out = OutputPath.make(for: file, ext: ext, suffix: " (oscurata)")
        let uti = UTType(filenameExtension: ext)?.identifier ?? UTType.jpeg.identifier
        try ImageConverter.write(try render(output.cropped(to: extent)), to: out, uti: uti,
                                 props: [kCGImageDestinationLossyCompressionQuality as String: 0.92])
        return out
    }

    private static func looksLikePlate(_ text: String) -> Bool {
        let compact = text.uppercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "·" }
        guard (5...9).contains(compact.count), compact.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return compact.contains(where: \.isLetter) && compact.contains(where: \.isNumber)
    }
}
