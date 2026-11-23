import AVFoundation
import Foundation

/// "Mini" (click the center of the nebula): makes files smaller.
/// Images are scaled down and recompressed, videos go to HEVC 1080p, audio to AAC,
/// PDFs get their images optimized, everything else is zipped.
/// A result that isn't smaller than the original is thrown away.
enum Miniaturizer {
    static func run(_ src: URL, progress: @escaping ProgressHandler) async throws -> URL {
        let kind = FileInspector.kind(of: src)
        let out: URL

        switch kind {
        case .image:
            out = try ImageConverter.miniaturize(src)
        case .video where FileInspector.isNativeMedia(src):
            out = OutputPath.make(for: src, ext: "mov", suffix: " (mini)")
            try await MediaConverter.export(AVURLAsset(url: src), preset: AVAssetExportPresetHEVC1920x1080,
                                            type: .mov, to: out, progress: progress)
        case .audio where FileInspector.isNativeMedia(src):
            out = OutputPath.make(for: src, ext: "m4a", suffix: " (mini)")
            try await MediaConverter.export(AVURLAsset(url: src), preset: AVAssetExportPresetAppleM4A,
                                            type: .m4a, to: out, progress: progress)
        case .pdf:
            out = try PDFConverter.miniaturize(src)
        case .video, .audio:
            guard FFmpeg.path != nil else { out = try await Archiver.zip([src]); break }
            out = try await FFmpeg.convert(src, to: kind == .video ? miniVideo : miniAudio, progress: progress)
        default:
            out = try await Archiver.zip([src])
        }

        if kind != .folder, let before = size(of: src), let after = size(of: out), after >= before {
            try? FileManager.default.removeItem(at: out)
            throw ConversionError.failed("\(src.lastPathComponent) è già compresso al massimo")
        }
        return out
    }

    /// Mini toggle on: shrink a freshly converted file, keeping the smaller one.
    static func shrink(_ url: URL) async -> URL {
        do {
            let mini = try await run(url) { _ in }
            try? FileManager.default.removeItem(at: url)
            return mini
        } catch {
            return url
        }
    }

    private static let miniVideo = ConversionTarget(id: "video.mp4", label: "Mini", ext: "mp4", symbol: "film", suffix: " (mini)")
    private static let miniAudio = ConversionTarget(id: "audio.m4a", label: "Mini", ext: "m4a", symbol: "waveform", suffix: " (mini)")

    private static func size(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }
}
