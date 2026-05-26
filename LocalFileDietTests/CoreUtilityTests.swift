import PDFKit
import XCTest
@testable import LocalFileDiet

final class CoreUtilityTests: XCTestCase {
    func testTargetSizeParsing() {
        XCTAssertEqual(TargetSizeParser.parse("2.5", unit: .mb), 2_500_000)
        XCTAssertEqual(TargetSizeParser.parse("800", unit: .kb), 800_000)
        XCTAssertNil(TargetSizeParser.parse("abc", unit: .mb))
    }

    func testByteFormattingProducesValue() {
        XCTAssertFalse(FileSizeFormat.string(from: 1_500_000).isEmpty)
    }

    func testQualityModeRangesAreOrdered() {
        for mode in QualityMode.allCases {
            XCTAssertLessThan(mode.compressionQualityRange.lowerBound, mode.compressionQualityRange.upperBound)
        }
    }

    func testOutputFilenameGeneration() {
        XCTAssertEqual(OutputFilename.make(original: "scan.pdf", outputExtension: "jpg"), "scan-compressed.jpg")
    }

    func testVideoBitrateEstimate() {
        let bitrate = VideoBitratePlanner.targetBitrateBitsPerSecond(targetSizeBytes: 10_000_000, durationSeconds: 20)
        XCTAssertGreaterThan(bitrate, 3_000_000)
    }

    func testProgressPresentationDoesNotMoveBackwards() {
        let current = CompressionProgress(
            phase: .encoding,
            fractionCompleted: 0.72,
            message: "Encoding"
        )
        let next = CompressionProgress(
            phase: .optimizing,
            fractionCompleted: 0.38,
            message: "Trying a better pass"
        )

        let smoothed = ProgressPresentation.smoothed(current: current, next: next)

        XCTAssertEqual(smoothed.fractionCompleted, 0.72)
        XCTAssertEqual(smoothed.phase, .optimizing)
        XCTAssertEqual(smoothed.message, "Trying a better pass")
    }
}
