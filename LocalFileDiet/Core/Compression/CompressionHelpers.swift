import Foundation

enum CompressionMath {
    static func reductionPercent(original: Int64, compressed: Int64) -> Double {
        guard original > 0 else { return 0 }
        return max(0, (1 - (Double(compressed) / Double(original))) * 100)
    }

    static func targetReached(size: Int64, target: Int64?) -> Bool {
        guard let target else { return size > 0 }
        return size <= target
    }

    static func estimatedReduction(original: Int64, estimated: Int64?) -> Double? {
        guard let estimated else { return nil }
        return reductionPercent(original: original, compressed: estimated)
    }
}

/// Guarantees an engine never returns a file that is not smaller than the input.
///
/// Every engine funnels its finished candidate through `resolve` before building
/// its `CompressionResult`, so a compression pass that made the file bigger (or
/// exactly the same size) hands the untouched original back instead.
enum OutputGuard {
    /// Compares `candidateURL` against the original. If the candidate is not
    /// meaningfully smaller, the ORIGINAL bytes are copied to a fresh output URL
    /// (preserving the original's file extension so the bytes and extension agree)
    /// and that URL is returned.
    /// - Returns: the URL to hand back, plus whether the original was kept.
    static func resolve(
        candidateURL: URL,
        input: CompressionInput,
        store: TemporaryFileStoring,
        fileManager: FileManager
    ) async throws -> (url: URL, keptOriginal: Bool) {
        // A missing or empty candidate is a real export failure, not a
        // "keep the original" situation.
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            throw AppError.exportFailed
        }
        let candidateSize = fileManager.fileSize(at: candidateURL)
        guard candidateSize > 0 else {
            throw AppError.exportFailed
        }

        // The bytes on disk are the ground truth for what the user would receive.
        let workingSize = fileManager.fileSize(at: input.workingURL)
        let originalSize = workingSize > 0 ? workingSize : input.originalSizeBytes
        // Exactly equal counts as NOT smaller.
        if originalSize <= 0 || candidateSize < originalSize {
            return (candidateURL, false)
        }
        // Without readable original bytes there is nothing better to hand back.
        guard workingSize > 0 else {
            return (candidateURL, false)
        }

        let keptURL = try await store.makeOutputURL(
            originalFilename: input.originalFilename,
            extension: originalExtension(input: input, candidateURL: candidateURL)
        )
        if fileManager.fileExists(atPath: keptURL.path) {
            try? fileManager.removeItem(at: keptURL)
        }
        try fileManager.copyItem(at: input.workingURL, to: keptURL)
        try? fileManager.removeItem(at: candidateURL)
        return (keptURL, true)
    }

    /// Warning bookkeeping for a kept-original outcome: flag it, and drop a
    /// "target may be unrealistic" caution only when the original really does
    /// satisfy the target.
    static func warningsAfterKeepingOriginal(
        _ warnings: [CompressionWarning],
        finalSize: Int64,
        target: Int64?
    ) -> [CompressionWarning] {
        var updated = warnings
        if CompressionMath.targetReached(size: finalSize, target: target) {
            updated.removeAll { $0.id == CompressionWarning.targetMayBeUnrealistic.id }
        }
        updated.append(.keptOriginal)
        return updated
    }

    private static func originalExtension(input: CompressionInput, candidateURL: URL) -> String {
        let fromOriginal = URL(fileURLWithPath: input.originalFilename).pathExtension
        if !fromOriginal.isEmpty { return fromOriginal }
        let fromCandidate = candidateURL.pathExtension
        if !fromCandidate.isEmpty { return fromCandidate }
        return "bin"
    }
}

enum OutputFilename {
    static func make(original: String, outputExtension: String) -> String {
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let clean = base.isEmpty ? "compressed-file" : base
        return "\(clean)-compressed.\(outputExtension)"
    }
}

extension FileManager {
    func fileSize(at url: URL) -> Int64 {
        let attributes = try? attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
