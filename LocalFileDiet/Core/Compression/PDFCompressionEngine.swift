import Foundation
import PDFKit
import UIKit

struct PDFAnalysis: Sendable, Hashable {
    let pageCount: Int
    let extractedTextCharacters: Int
    let averageBytesPerPage: Int64
    let hasAnnotations: Bool

    var isLikelyScanned: Bool {
        pageCount > 0 && extractedTextCharacters / max(pageCount, 1) < 80 && averageBytesPerPage > 450_000
    }
}

struct PDFAnalyzer {
    func analyze(document: PDFDocument, fileSize: Int64) -> PDFAnalysis {
        let pageCount = document.pageCount
        var textCharacters = 0
        var hasAnnotations = false

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            textCharacters += page.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            if !page.annotations.isEmpty {
                hasAnnotations = true
            }
        }

        return PDFAnalysis(
            pageCount: pageCount,
            extractedTextCharacters: textCharacters,
            averageBytesPerPage: pageCount == 0 ? fileSize : fileSize / Int64(pageCount),
            hasAnnotations: hasAnnotations
        )
    }
}

struct PDFCompressionEngine: CompressionEngine {
    private let store: TemporaryFileStoring
    private let analyzer: PDFAnalyzer
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, analyzer: PDFAnalyzer = PDFAnalyzer(), fileManager: FileManager = .default) {
        self.store = store
        self.analyzer = analyzer
        self.fileManager = fileManager
    }

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        let document = try openDocument(input.workingURL)
        let analysis = analyzer.analyze(document: document, fileSize: input.originalSizeBytes)
        var warnings: [CompressionWarning] = []
        var operations: [CompressionOperation] = [.verifyOutput]

        if shouldRasterize(analysis: analysis, settings: settings) {
            warnings.append(.rasterizesPDF)
            operations.insert(.pdfRasterRebuild, at: 0)
            operations.insert(.reencode, at: 1)
        } else {
            warnings.append(.vectorPDFProtected)
            operations.insert(.reencode, at: 0)
        }
        if analysis.hasAnnotations {
            warnings.append(CompressionWarning(
                id: "pdfAnnotations",
                severity: .caution,
                title: "PDF has annotations",
                message: "Interactive annotations or forms may not survive aggressive scan compression."
            ))
        }
        if let target = settings.targetSizeBytes, input.originalSizeBytes > target * 10 {
            warnings.append(.targetMayBeUnrealistic)
        }

        let ratio: Double = analysis.isLikelyScanned ? 0.45 : 0.92
        let estimated = Int64(Double(input.originalSizeBytes) * ratio)
        return CompressionEstimate(
            estimatedSizeBytes: estimated,
            estimatedReductionPercent: CompressionMath.estimatedReduction(original: input.originalSizeBytes, estimated: estimated),
            predictedQuality: analysis.isLikelyScanned ? quality(for: settings) : .excellent,
            warnings: warnings,
            plannedOperations: operations
        )
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let start = Date()
        progress(.preparing)
        let document = try openDocument(input.workingURL)
        let analysis = analyzer.analyze(document: document, fileSize: input.originalSizeBytes)
        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: "pdf")
        let shouldRasterize = shouldRasterize(analysis: analysis, settings: settings)
        var warnings: [CompressionWarning] = []
        var operations: [CompressionOperation] = [.verifyOutput]

        if shouldRasterize {
            warnings.append(.rasterizesPDF)
            operations.append(.pdfRasterRebuild)
            operations.append(.reencode)
            progress(CompressionProgress(phase: .optimizing, fractionCompleted: 0.12, message: "Optimizing scanned PDF"))
            try await rasterRebuild(document: document, input: input, settings: settings, outputURL: outputURL, progress: progress)
        } else {
            warnings.append(.vectorPDFProtected)
            operations.append(.reencode)
            progress(CompressionProgress(phase: .writing, fractionCompleted: 0.4, message: "Rewriting PDF safely"))
            try conservativeRewrite(document: document, outputURL: outputURL)
        }

        if analysis.hasAnnotations {
            warnings.append(CompressionWarning(
                id: "pdfAnnotations",
                severity: .caution,
                title: "PDF has annotations",
                message: "Interactive annotations or forms may not survive aggressive scan compression."
            ))
        }

        try Task.checkCancellation()
        let finalSize = fileManager.fileSize(at: outputURL)
        guard finalSize > 0 else {
            throw AppError.exportFailed
        }
        if let target = settings.targetSizeBytes, finalSize > target {
            warnings.append(.targetMayBeUnrealistic)
        }
        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "PDF ready"))
        return CompressionResult(
            outputURL: outputURL,
            outputFilename: outputURL.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: settings.targetSizeBytes),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: warnings,
            operationsApplied: operations.unique(),
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    private func openDocument(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw AppError.corruptFile
        }
        if document.isLocked {
            throw AppError.protectedPDF
        }
        return document
    }

    private func shouldRasterize(analysis: PDFAnalysis, settings: CompressionSettings) -> Bool {
        if settings.qualityMode == .smallestFile {
            return true
        }
        return analysis.isLikelyScanned
    }

    private func conservativeRewrite(document: PDFDocument, outputURL: URL) throws {
        guard let data = document.dataRepresentation(), !data.isEmpty else {
            throw AppError.exportFailed
        }
        try data.write(to: outputURL, options: [.atomic])
    }

    private func rasterRebuild(
        document: PDFDocument,
        input: CompressionInput,
        settings: CompressionSettings,
        outputURL: URL,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws {
        let target = settings.targetSizeBytes
        let qualityRange = settings.qualityMode.compressionQualityRange
        var attempts: [(dpi: CGFloat, quality: CGFloat)] = []

        for dpi in settings.qualityMode.pdfDPISequence {
            attempts.append((dpi, CGFloat(qualityRange.upperBound)))
            attempts.append((dpi, CGFloat((qualityRange.lowerBound + qualityRange.upperBound) / 2)))
            attempts.append((dpi, CGFloat(qualityRange.lowerBound)))
        }

        var bestURL: URL?
        var bestSize = Int64.max
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent("PDF-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        for (index, attempt) in attempts.enumerated() {
            try Task.checkCancellation()
            let attemptURL = tempDirectory.appendingPathComponent("attempt-\(index).pdf")
            try render(document: document, to: attemptURL, dpi: attempt.dpi, jpegQuality: attempt.quality, progress: progress)
            let size = fileManager.fileSize(at: attemptURL)
            if size < bestSize {
                bestSize = size
                bestURL = attemptURL
            }
            if let target, size <= target {
                try fileManager.copyItem(at: attemptURL, to: outputURL)
                return
            }
        }

        guard let bestURL else {
            throw AppError.exportFailed
        }
        try fileManager.copyItem(at: bestURL, to: outputURL)
    }

    private func render(
        document: PDFDocument,
        to outputURL: URL,
        dpi: CGFloat,
        jpegQuality: CGFloat,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) throws {
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        let pageCount = max(document.pageCount, 1)
        let data = renderer.pdfData { context in
            for pageIndex in 0..<document.pageCount {
                if Task.isCancelled { return }
                guard let page = document.page(at: pageIndex) else { continue }
                let pageBounds = page.bounds(for: .mediaBox)
                context.beginPage(withBounds: pageBounds, pageInfo: [:])
                let image = renderPage(page, bounds: pageBounds, dpi: dpi)
                if let jpegData = image.jpegData(compressionQuality: jpegQuality),
                   let compressedImage = UIImage(data: jpegData) {
                    compressedImage.draw(in: pageBounds)
                } else {
                    image.draw(in: pageBounds)
                }
                progress(CompressionProgress(
                    phase: .encoding,
                    fractionCompleted: 0.2 + (Double(pageIndex + 1) / Double(pageCount)) * 0.62,
                    message: "Compressing page \(pageIndex + 1) of \(pageCount)"
                ))
            }
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        try data.write(to: outputURL, options: [.atomic])
    }

    private func renderPage(_ page: PDFPage, bounds: CGRect, dpi: CGFloat) -> UIImage {
        let scale = max(dpi / 72, 1)
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: pixelSize))
            rendererContext.cgContext.saveGState()
            rendererContext.cgContext.scaleBy(x: scale, y: scale)
            rendererContext.cgContext.translateBy(x: -bounds.minX, y: bounds.height - bounds.minY)
            rendererContext.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: rendererContext.cgContext)
            rendererContext.cgContext.restoreGState()
        }
    }

    private func quality(for settings: CompressionSettings) -> PredictedQuality {
        switch settings.qualityMode {
        case .bestQuality: .excellent
        case .balanced: .good
        case .smallestFile: .acceptable
        }
    }
}
