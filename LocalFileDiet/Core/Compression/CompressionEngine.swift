import Foundation

protocol CompressionEngine {
    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate
    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult
}

struct CompressionRouter {
    private let imageEngine: CompressionEngine
    private let pdfEngine: CompressionEngine
    private let videoEngine: CompressionEngine
    private let archiveEngine: CompressionEngine
    private let unsupportedEngine: CompressionEngine

    init(store: TemporaryFileStoring) {
        self.imageEngine = ImageCompressionEngine(store: store)
        self.pdfEngine = PDFCompressionEngine(store: store)
        self.videoEngine = VideoCompressionEngine(store: store)
        self.archiveEngine = ArchiveCompressionEngine(store: store)
        self.unsupportedEngine = PassthroughUnsupportedEngine()
    }

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        try await engine(for: input.fileKind).estimate(input: input, settings: settings)
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        try Task.checkCancellation()
        AppLogger.compression.info("compression_started kind=\(input.fileKind.rawValue, privacy: .public) sizeBucket=\(AppLogger.sizeBucket(for: input.originalSizeBytes), privacy: .public)")
        let result = try await engine(for: input.fileKind).compress(input: input, settings: settings, progress: progress)
        AppLogger.compression.info("compression_completed kind=\(input.fileKind.rawValue, privacy: .public) targetReached=\(result.targetReached, privacy: .public)")
        return result
    }

    private func engine(for kind: FileKind) -> CompressionEngine {
        switch kind {
        case .image:
            imageEngine
        case .pdf:
            pdfEngine
        case .video:
            videoEngine
        case .archive:
            archiveEngine
        case .unsupported:
            unsupportedEngine
        }
    }
}

struct PassthroughUnsupportedEngine: CompressionEngine {
    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        CompressionEstimate(
            estimatedSizeBytes: nil,
            estimatedReductionPercent: nil,
            predictedQuality: .low,
            warnings: [
                CompressionWarning(
                    id: "unsupported",
                    severity: .blocking,
                    title: "Unsupported file",
                    message: "This file type is not supported yet. Try a PDF, image, video, or ZIP file."
                )
            ],
            plannedOperations: []
        )
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        throw AppError.unsupportedFileType
    }
}

