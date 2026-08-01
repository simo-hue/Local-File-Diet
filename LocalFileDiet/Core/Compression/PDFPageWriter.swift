import CoreGraphics
import Foundation
import ImageIO
import PDFKit
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
    ///
    /// `rotation` is for pages whose content was deliberately left in the source
    /// page's own orientation instead of being turned upright — see
    /// `PageGeometry(page:bakingRotation:)`. Core Graphics publishes constants
    /// for the box keys only, but it does write a raw `Rotate` entry straight
    /// through into the page dictionary (measured on this SDK: 90, 180 and 270
    /// all come back from `CGPDFPage.rotationAngle` and from PDFKit). Because
    /// that key is undocumented, `PDFInteractiveContent.restore` sets the same
    /// rotation again through PDFKit, so a release that stopped honouring it
    /// would still produce a correctly oriented file.
    func writePage(mediaBox: CGRect, rotation: Int = 0, draw: (CGContext) throws -> Void) rethrows {
        var box = mediaBox
        // `kCGPDFContextMediaBox` wants the raw bytes of a CGRect, not a number.
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        var pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: boxData]
        let turn = ((rotation % 360) + 360) % 360
        if turn != 0 {
            pageInfo["Rotate" as CFString] = turn
        }
        context.beginPDFPage(pageInfo as CFDictionary)
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

/// Puts back the parts of a PDF that do not live in a page's content stream.
///
/// `CGContext.drawPDFPage` replays a page's drawing operators and nothing else.
/// Annotations hang off the page dictionary and the outline hangs off the
/// document catalog, so a file written by `PDFPageWriter` comes out with no
/// links, no notes, no highlights and no bookmarks — on EVERY page, not only the
/// rebuilt ones. This re-opens the finished file with PDFKit and moves the
/// source document's interactive content onto it.
///
/// Rebuilding an annotated page is still worth it. Measured by running the
/// engine over the same fixture twice, once with this pass and once without:
/// on a 2,027,151-byte, three-page document carrying 13 annotations and a
/// three-entry outline, the pass adds 20,243 bytes to a 1,500,314-byte render —
/// 1.3%. Refusing to rebuild an annotated photo page instead would keep that
/// page's source image, which in the same fixture is about 1.01 MB against the
/// 0.24 MB it rebuilds to. The engine budgets for those bytes before it starts;
/// see `PDFCompressionEngine.interactiveContentReserve`.
enum PDFInteractiveContent {
    /// Outline nesting the copy is willing to follow.
    ///
    /// `copyOutline` recurses once per level, and the engine calls `restore`
    /// from an async function, so it runs on a cooperative thread with a small
    /// stack rather than on the main one. Measured there with the cap removed,
    /// the recursion survived 1,000 levels and died with SIGBUS at 1,200 in an
    /// optimised build (800 and 1,000 unoptimised). Real outlines are a handful
    /// of levels deep, so this cap is far above any genuine document and well
    /// below the crash. Anything nested deeper is dropped rather than followed.
    static let maximumOutlineDepth = 64

    /// One page of the output, and where it came from.
    struct PageLink: Sendable {
        let sourcePageIndex: Int
        /// The transform the page's content went through on its way into the
        /// output, so an annotation payload can follow it.
        ///
        /// This is a translation for every page the writer produced: pages that
        /// carry annotations keep the source page's own orientation and get a
        /// `/Rotate` instead (see `sourceRotation`), because PDFKit will not
        /// turn `/QuadPoints`, `/InkList` or a custom `/AP` with the bounds.
        let transform: CGAffineTransform
        /// The `/Rotate` the output page has to carry, for a page whose content
        /// was left in the source's orientation. Zero for a page the writer
        /// turned upright itself.
        let sourceRotation: Int

        init(sourcePageIndex: Int, transform: CGAffineTransform, sourceRotation: Int = 0) {
            self.sourcePageIndex = sourcePageIndex
            self.transform = transform
            self.sourceRotation = sourceRotation
        }
    }

    /// What actually made it across, so the warnings can say only that.
    struct Outcome: Sendable, Hashable {
        var annotationsCopied = 0
        var outlineCopied = false
        /// At least one fill-in form field was carried over. Its name and value
        /// come with it, but PDFKit will not write the document-level form
        /// dictionary into a file it did not open, so the field stops being
        /// fillable — see `CompressionWarning.pdfFormFields`.
        var carriedFormFields = false
        /// The source had something to carry and it could not be written back.
        var failed = false

        var carriedAnything: Bool { annotationsCopied > 0 || outlineCopied }
    }

    /// - Parameters:
    ///   - outputURL: the finished Core Graphics pass. Replaced in place.
    ///   - sourceURL: the document the pass was built from.
    ///   - pages: one entry per page of the output, in order.
    ///   - stagingDirectory: where the rewritten file is built before it is
    ///     swapped in. PDFKit is still reading `outputURL`, so writing straight
    ///     over it would truncate the file underneath itself.
    static func restore(
        into outputURL: URL,
        from sourceURL: URL,
        pages: [PageLink],
        stagingDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        var outcome = Outcome()
        guard let source = PDFDocument(url: sourceURL), !source.isLocked,
              let output = PDFDocument(url: outputURL) else {
            return outcome
        }

        // A page the writer left in the source's orientation needs its `/Rotate`
        // back. The Core Graphics pass already wrote one, so this is normally a
        // no-op; it is here so the file is still right if that undocumented key
        // ever stops working, and `rotationsApplied` then forces the rewrite
        // below even when there is no interactive content to carry.
        var rotationsApplied = 0
        for (outputIndex, link) in pages.enumerated() {
            try Task.checkCancellation()
            guard let sourcePage = source.page(at: link.sourcePageIndex),
                  let outputPage = output.page(at: outputIndex) else {
                continue
            }
            if outputPage.rotation != link.sourceRotation {
                outputPage.rotation = link.sourceRotation
                rotationsApplied += 1
            }
            for annotation in sourcePage.annotations {
                // PDFKit creates a popup for the note or highlight it belongs to
                // as soon as that annotation is added, so carrying the source's
                // popup across as well leaves two of them stacked on the page.
                guard annotation.type != "Popup" else { continue }
                annotation.bounds = annotation.bounds.applying(link.transform)
                outputPage.addAnnotation(annotation)
                outcome.annotationsCopied += 1
                if annotation.type == "Widget" {
                    outcome.carriedFormFields = true
                }
            }
        }

        if let root = source.outlineRoot, root.numberOfChildren > 0 {
            output.outlineRoot = copyOutline(root, from: source, to: output)
            outcome.outlineCopied = true
        }

        // Nothing interactive in the document and nothing to re-orient: leave
        // the pass exactly as the Core Graphics writer streamed it.
        guard outcome.carriedAnything || rotationsApplied > 0 else { return outcome }

        try Task.checkCancellation()
        let staged = stagingDirectory.appendingPathComponent("interactive-\(UUID().uuidString).pdf")
        guard output.write(to: staged), fileManager.fileSize(at: staged) > 0 else {
            try? fileManager.removeItem(at: staged)
            return Outcome(failed: true)
        }
        do {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            return Outcome(failed: true)
        }
        return outcome
    }

    /// Rebuilds an outline against the output's pages.
    ///
    /// A `PDFDestination` holds a `PDFPage`, and the source's pages are not the
    /// output's, so the tree is copied node by node with each destination
    /// re-pointed at the page in the same position. Moving the source's
    /// `outlineRoot` across wholesale writes the labels but sends every entry
    /// that pointed at a rebuilt page to page 1.
    ///
    /// `depth` stops a bookmark tree nested past `maximumOutlineDepth` from
    /// taking the stack down with it.
    private static func copyOutline(
        _ node: PDFOutline,
        from source: PDFDocument,
        to output: PDFDocument,
        depth: Int = 0
    ) -> PDFOutline {
        let copy = PDFOutline()
        copy.label = node.label
        copy.isOpen = node.isOpen
        if let destination = node.destination,
           let page = destination.page,
           case let index = source.index(for: page),
           index >= 0, index < output.pageCount,
           let outputPage = output.page(at: index) {
            copy.destination = PDFDestination(page: outputPage, at: destination.point)
        } else if let action = node.action {
            copy.action = action
        }
        guard depth < maximumOutlineDepth else { return copy }
        for position in 0..<node.numberOfChildren {
            guard let child = node.child(at: position) else { continue }
            copy.insertChild(
                copyOutline(child, from: source, to: output, depth: depth + 1),
                at: copy.numberOfChildren
            )
        }
        return copy
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
