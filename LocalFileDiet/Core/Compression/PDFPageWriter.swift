import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The one place in the app that writes PDF pages.
///
/// `UIGraphicsPDFRenderer` used to do this job in two different engines. It is
/// UIKit-only, it forces every page through a `UIImage`, and it can only build
/// the whole document in memory. A Core Graphics PDF context writes the same
/// file, takes a `CGImage` directly, and can stream straight to disk — which
/// matters when the document is a 200-page scan.
///
/// The writer is deliberately not `Sendable`: a `CGContext` is a stateful
/// drawing target and must stay on the thread that is filling it.
struct PDFPageWriter {
    private let context: CGContext
    private let backingData: NSMutableData?

    /// Builds the document in memory. `finish()` hands back the bytes.
    init(documentInfo: [CFString: Any] = [:]) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, documentInfo as CFDictionary) else {
            throw AppError.exportFailed
        }
        self.context = context
        self.backingData = data
    }

    /// Streams the document straight to `url`, so a large rebuild never has to
    /// exist as one `Data` in memory. `finish()` returns `nil` because the bytes
    /// are already on disk.
    init(url: URL, documentInfo: [CFString: Any] = [:]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, documentInfo as CFDictionary) else {
            throw AppError.exportFailed
        }
        self.context = context
        self.backingData = nil
    }

    /// Adds one page of the given size and lets `draw` fill it.
    ///
    /// The context handed to the closure is in PDF user space: the origin is the
    /// bottom-left corner of `mediaBox` and y grows upwards.
    func writePage(mediaBox: CGRect, draw: (CGContext) throws -> Void) rethrows {
        var box = mediaBox
        // `kCGPDFContextMediaBox` wants the raw bytes of a CGRect, not a number.
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        // The page has to be closed even when the drawing throws, otherwise the
        // context is left mid-page and the file on disk is unreadable.
        defer { context.endPDFPage() }
        try draw(context)
    }

    /// Closes the document. Call exactly once.
    /// - Returns: the bytes for an in-memory writer, `nil` for a file writer.
    @discardableResult
    func finish() -> Data? {
        context.closePDF()
        context.flush()
        guard let backingData else { return nil }
        return backingData as Data
    }
}

/// JPEG encoding for images that are about to be embedded in a PDF page.
enum PDFImageEncoder {
    /// JPEG-encodes `image` and returns a `CGImage` that is backed by those JPEG
    /// bytes rather than by a decoded bitmap.
    ///
    /// This round trip is the point, not an accident: Core Graphics embeds a
    /// JPEG-backed image into a PDF page as its original `DCTDecode` stream, so
    /// the page's byte count follows the quality knob. Handing the raw bitmap to
    /// the PDF context instead would let Core Graphics choose its own (lossless,
    /// far larger) encoding and the quality value would do nothing.
    ///
    /// The returned image is lazy — no second full-size bitmap is decoded here.
    static func jpegBackedImage(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = try jpegData(image, quality: quality)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let backed = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppError.exportFailed
        }
        return backed
    }

    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw AppError.exportFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.01), 1),
            // The pixels are already in their final orientation.
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0 else {
            throw AppError.exportFailed
        }
        return data as Data
    }
}
