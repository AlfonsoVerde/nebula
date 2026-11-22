import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum MediaConverter {
    // MARK: Video

    static func convertVideo(_ src: URL, to t: ConversionTarget, progress: @escaping ProgressHandler) async throws -> URL {
        let asset = AVURLAsset(url: src)
        let out = OutputPath.make(for: src, ext: t.ext, suffix: t.suffix)
        switch t.tag {
        case "mp4":
            try await export(asset, preset: AVAssetExportPresetHighestQuality, type: .mp4, to: out, progress: progress)
        case "mov":
            try await export(asset, preset: AVAssetExportPresetHighestQuality, type: .mov, to: out, progress: progress)
        case "hevc":
            try await export(asset, preset: AVAssetExportPresetHEVCHighestQuality, type: .mov, to: out, progress: progress)
        case "m4a":
            try await export(asset, preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out, progress: progress)
        case "gif":
            try await makeGIF(asset, to: out, progress: progress)
        case "png":
            try await poster(asset, to: out)
        default:
            throw ConversionError.unsupported
        }
        return out
    }

    // MARK: Audio

    static func convertAudio(_ src: URL, to t: ConversionTarget, progress: @escaping ProgressHandler) async throws -> URL {
        let out = OutputPath.make(for: src, ext: t.ext, suffix: t.suffix)
        switch t.tag {
        case "m4a":
            try await export(AVURLAsset(url: src), preset: AVAssetExportPresetAppleM4A, type: .m4a, to: out, progress: progress)
        case "wav", "aiff", "caf":
            try pcm(src, to: out, bigEndian: t.tag == "aiff", progress: progress)
        default:
            throw ConversionError.unsupported
        }
        return out
    }

    // MARK: Helpers

    static func export(_ asset: AVAsset, preset: String, type: AVFileType, to out: URL,
                       progress: @escaping ProgressHandler) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("Questo file non si può esportare con questo formato")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true

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
            throw session.error ?? ConversionError.failed("Esportazione non riuscita")
        }
    }

    /// Video → animated GIF (max 15 s, 12 fps, 520 px).
    static func makeGIF(_ asset: AVAsset, to out: URL, progress: @escaping ProgressHandler) async throws {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw ConversionError.failed("Durata del video non valida") }

        let fps = 12.0
        let count = max(1, Int(min(duration, 15) * fps))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 520)
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConversionError.failed("Impossibile creare la GIF")
        }
        let loop = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, loop as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: 1.0 / fps,
            kCGImagePropertyGIFUnclampedDelayTime as String: 1.0 / fps
        ]] as CFDictionary

        for i in 0..<count {
            let time = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(dest, image, frameProps)
            progress(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Impossibile scrivere la GIF") }
    }

    /// Grabs a frame (at 1 s, or mid-clip for very short videos) as PNG.
    static func poster(_ asset: AVAsset, to out: URL) async throws {
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let seconds = duration.isFinite ? min(1, duration / 2) : 0
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        try ImageConverter.write(image, to: out, uti: UTType.png.identifier)
    }

    /// Any readable audio → 16-bit PCM (WAV/AIFF/CAF, type inferred from the extension).
    static func pcm(_ src: URL, to out: URL, bigEndian: Bool, progress: @escaping ProgressHandler) throws {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(forWriting: out, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else {
            throw ConversionError.failed("Buffer audio non disponibile")
        }
        let total = Double(max(input.length, 1))
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            progress(Double(input.framePosition) / total)
        }
    }
}

// MARK: - FFmpeg (optional, for WebM/MKV/MP3/FLAC/OGG/WebP and non-native inputs)

enum FFmpeg {
    static let path: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static func arguments(for t: ConversionTarget) -> [String] {
        switch t.tag {
        case "mp4": ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov": ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        case "hevc": ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-c:a", "aac"]
        case "webm": ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-c:a", "libopus"]
        case "mkv": ["-c", "copy"]
        case "gif": ["-t", "15", "-vf", "fps=12,scale=520:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case "png": ["-frames:v", "1"]
        case "m4a": ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "mp3": ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": ["-vn", "-c:a", "pcm_s16be"]
        case "caf": ["-vn", "-c:a", "pcm_s16le"]
        case "flac": ["-vn", "-c:a", "flac"]
        case "ogg": ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case "webp": ["-c:v", "libwebp", "-quality", "90"]
        default: []
        }
    }

    static func convert(_ src: URL, to t: ConversionTarget, progress: @escaping ProgressHandler) async throws -> URL {
        guard let path else {
            throw ConversionError.failed("Serve FFmpeg per questo formato: brew install ffmpeg")
        }
        let out = OutputPath.make(for: src, ext: t.ext, suffix: t.suffix)
        let durationSeconds = try? await AVURLAsset(url: src).load(.duration).seconds
        let duration = (durationSeconds?.isFinite == true && (durationSeconds ?? 0) > 0) ? durationSeconds : nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", src.path]
            + arguments(for: t)
            + ["-progress", "pipe:1", "-nostats", out.path]

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), let duration else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                if let micro = Double(line.dropFirst("out_time_us=".count)) {
                    progress(min(micro / 1_000_000 / duration, 0.99))
                }
            }
        }
        defer { stdout.fileHandleForReading.readabilityHandler = nil }
        do {
            try await ProcessRunner.run(process, errorPipe: stderr)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}
