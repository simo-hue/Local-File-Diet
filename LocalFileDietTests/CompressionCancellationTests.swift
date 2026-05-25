import Foundation
import XCTest
@testable import LocalFileDiet

final class CompressionCancellationTests: XCTestCase {
    func testCancellationIsSurfaced() async {
        let engine = SlowTestEngine()
        let input = CompressionInput(
            id: UUID(),
            originalURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            workingURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            originalFilename: "a.jpg",
            fileExtension: "jpg",
            detectedTypeIdentifier: "public.jpeg",
            fileKind: .image,
            originalSizeBytes: 1_000,
            createdAt: Date()
        )

        let task = Task {
            try await engine.compress(input: input, settings: .balanced) { _ in }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private struct SlowTestEngine: CompressionEngine {
    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        CompressionEstimate(estimatedSizeBytes: nil, estimatedReductionPercent: nil, predictedQuality: .good, warnings: [], plannedOperations: [])
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        try await Task.sleep(for: .seconds(2))
        throw CancellationError()
    }
}

