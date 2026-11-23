import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageConverter {
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static var canWriteWebP: Bool { writableTypes.contains("org.webmproject.webp") }

    struct Frame {
        let image: CGImage
        let delay: Double?
    }

    static func convert(_ src: URL, to t: ConversionTarget) throws -> URL {
        let (frames, metadata) = try load(src)
        let out = OutputPath.make(for: src, ext: t.ext, suffix: t.suffix)

        if t.ext == "pdf" {
            let doc = PDFDocument()
            for frame in frames {
                let image = NSImage(cgImage: frame.image, size: NSSize(width: frame.image.width, height: frame.image.height))
                if let page = PDFPage(image: image) { doc.insert(page, at: doc.pageCount) }
            }
            guard doc.write(to: out) else { throw ConversionError.failed("Impossibile salvare il file") }
            return out
        }

        try encode(frames, metadata: metadata, to: out, ext: t.ext, quality: 0.9)
        return out
    }

    /// "Mini": same format when it compresses well, smaller pixel size, lower quality.
    static func miniaturize(_ src: URL) throws -> URL {
        var ext = src.pathExtension.lowercased()
        if ext == "jpeg" { ext = "jpg" }
        if ext == "heif" { ext = "heic" }
        if !["jpg", "heic", "png", "gif"].contains(ext) { ext = "jpg" }
        let limit = ext == "gif" ? 480 : (ext == "png" ? 2048 : 2560)
        let (frames, metadata) = try load(src, maxPixel: limit)
        let out = OutputPath.make(for: src, ext: ext, suffix: tr(" (mini)"))
        try encode(frames, metadata: metadata, to: out, ext: ext, quality: 0.62)
        return out
    }

    static func encode(_ frames: [Frame], metadata: [String: Any], to out: URL, ext: String, quality: Double) throws {
        guard let uti = UTType(filenameExtension: ext)?.identifier else { throw ConversionError.unsupported }
        let animated = (ext == "gif" || ext == "tiff") && frames.count > 1
        let used = animated ? frames : [frames[0]]
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, used.count, nil) else {
            throw ConversionError.failed(tr("Formato %@ non scrivibile su questo Mac", ext.uppercased()))
        }
        if ext == "gif" && animated {
            let loop = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
            CGImageDestinationSetProperties(dest, loop as CFDictionary)
        }
        let opaque = ext == "jpg" || ext == "bmp"
        for frame in used {
            var props = metadata
            props[kCGImageDestinationLossyCompressionQuality as String] = quality
            if let delay = frame.delay, ext == "gif" {
                props[kCGImagePropertyGIFDictionary as String] = [kCGImagePropertyGIFDelayTime as String: delay]
            }
            CGImageDestinationAddImage(dest, opaque ? flatten(frame.image) : frame.image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Impossibile salvare il file") }
    }

    static func write(_ image: CGImage, to out: URL, uti: String, props: [String: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.failed("Impossibile salvare il file")
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.failed("Impossibile salvare il file") }
    }

    /// Loads all frames with EXIF orientation baked in, keeping EXIF/GPS/IPTC metadata.
    static func load(_ src: URL, maxPixel: Int? = nil) throws -> ([Frame], [String: Any]) {
        if let source = CGImageSourceCreateWithURL(src as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            let count = CGImageSourceGetCount(source)
            var frames: [Frame] = []
            var metadata: [String: Any] = [:]
            if let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
                for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                    if let value = first[key as String] { metadata[key as String] = value }
                }
            }
            for i in 0..<count {
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any]
                let w = props?[kCGImagePropertyPixelWidth as String] as? Int ?? 0
                let h = props?[kCGImagePropertyPixelHeight as String] as? Int ?? 0
                var image: CGImage?
                if max(w, h) > 0 {
                    let options: [String: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                        kCGImageSourceCreateThumbnailWithTransform as String: true,
                        kCGImageSourceThumbnailMaxPixelSize as String: min(max(w, h), maxPixel ?? Int.max),
                        kCGImageSourceShouldCacheImmediately as String: true
                    ]
                    image = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary)
                }
                guard let cg = image ?? CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double)
                    ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double)
                frames.append(Frame(image: cg, delay: delay))
            }
            if !frames.isEmpty { return (frames, metadata) }
        }

        // Fallback for formats ImageIO can't decode (e.g. SVG): rasterize via NSImage at 2×.
        guard let image = NSImage(contentsOf: src), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.failed("File non leggibile")
        }
        let w = Int(image.size.width * 2), h = Int(image.size.height * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw ConversionError.failed("Impossibile salvare il file")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { throw ConversionError.failed("Impossibile salvare il file") }
        return ([Frame(image: cg, delay: nil)], [:])
    }

    /// JPEG/BMP have no alpha: composite transparent images over white.
    static func flatten(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst: return image
        default: break
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return image
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}

// MARK: - PDF

enum PDFConverter {
    static func renderPages(_ src: URL, to t: ConversionTarget, progress: @escaping ProgressHandler) throws -> URL {
        guard let doc = PDFDocument(url: src), doc.pageCount > 0 else { throw ConversionError.failed("File non leggibile") }
        let uti = t.ext == "png" ? UTType.png.identifier : UTType.jpeg.identifier
        let props: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.9]

        if doc.pageCount == 1, let page = doc.page(at: 0) {
            let out = OutputPath.make(for: src, ext: t.ext)
            try ImageConverter.write(render(page), to: out, uti: uti, props: props)
            return out
        }
        let folder = try OutputPath.folder(for: src, suffix: " (\(t.label))")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let url = folder.appendingPathComponent(tr("Pagina %03d", i + 1)).appendingPathExtension(t.ext)
            try ImageConverter.write(render(page), to: url, uti: uti, props: props)
            progress(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }

    static func render(_ page: PDFPage, scale: CGFloat = 2) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let w = Int((rotated ? box.height : box.width) * scale)
        let h = Int((rotated ? box.width : box.height) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.failed("Impossibile salvare il file")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw ConversionError.failed("Impossibile salvare il file") }
        return image
    }

    static func miniaturize(_ src: URL) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConversionError.failed("File non leggibile") }
        let out = OutputPath.make(for: src, ext: "pdf", suffix: tr(" (mini)"))
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard doc.write(to: out, withOptions: options) else { throw ConversionError.failed("Impossibile salvare il file") }
        return out
    }

    @MainActor
    static func exportText(_ src: URL, to t: ConversionTarget) throws -> URL {
        guard let doc = PDFDocument(url: src) else { throw ConversionError.failed("File non leggibile") }
        let out = OutputPath.make(for: src, ext: t.ext)
        if t.ext == "txt" {
            try (doc.string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.attributedString {
                text.append(page)
                text.append(NSAttributedString(string: "\n\n"))
            }
        }
        try DocumentConverter.write(text, to: out, ext: t.ext)
        return out
    }
}
