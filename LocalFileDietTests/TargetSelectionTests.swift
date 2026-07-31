import Foundation
import XCTest
@testable import LocalFileDiet

final class TargetSelectionTests: XCTestCase {

    // MARK: - The picker must show what is actually in effect

    /// The regression this type exists for: the review screen hardcoded
    /// `selectedPreset = .forms` while the real target came from the saved
    /// default, so a user whose default was "Under 2 MB" saw "Under 10 MB".
    func testSavedDefaultDrivesBothThePickerAndTheTarget() throws {
        let defaults = try makeDefaults()
        defaults.set(TargetSizePreset.veryStrict2.rawValue, forKey: AppDefaults.defaultTargetPresetKey)

        let selection = TargetSelectionState.fromDefaults(defaults)

        XCTAssertEqual(selection.pickerOption, .preset(.veryStrict2))
        XCTAssertEqual(selection.targetSizeBytes, TargetSizePreset.veryStrict2.bytes)
        XCTAssertEqual(selection.pickerOption.title, "Under 2 MB")
    }

    func testEveryPresetRoundTripsThroughTheSavedDefault() throws {
        let defaults = try makeDefaults()
        for preset in TargetSizePreset.allCases {
            defaults.set(preset.rawValue, forKey: AppDefaults.defaultTargetPresetKey)
            let selection = TargetSelectionState.fromDefaults(defaults)
            XCTAssertEqual(selection.targetSizeBytes, preset.bytes)
            XCTAssertEqual(selection.pickerOption, .preset(preset))
        }
    }

    func testMissingDefaultFallsBackToTheShippedPreset() throws {
        let defaults = try makeDefaults()
        let selection = TargetSelectionState.fromDefaults(defaults)
        XCTAssertEqual(selection.pickerOption, .preset(.forms))
    }

    func testByteTargetsRebuildTheMatchingPresetOrACustomValue() {
        XCTAssertEqual(TargetSelectionState(targetBytes: 5_000_000).pickerOption, .preset(.strict5))
        XCTAssertEqual(TargetSelectionState(targetBytes: 3_300_000).pickerOption, .custom)
        XCTAssertEqual(TargetSelectionState(targetBytes: 3_300_000).targetSizeBytes, 3_300_000)
        XCTAssertEqual(TargetSelectionState(targetBytes: nil).pickerOption, .noLimit)
    }

    // MARK: - No limit

    func testNoLimitMeansNoTarget() {
        var selection = TargetSelectionState(mode: .preset(.forms))
        selection.select(.noLimit)
        XCTAssertNil(selection.targetSizeBytes)
        XCTAssertEqual(selection.pickerOption, .noLimit)
        XCTAssertNil(selection.validationMessage)
    }

    // MARK: - Custom values

    func testSwitchingToCustomAndBackIsCoherent() {
        var selection = TargetSelectionState(mode: .preset(.strict5))

        selection.select(.custom)
        XCTAssertEqual(selection.pickerOption, .custom)
        XCTAssertEqual(selection.targetSizeBytes, TargetSizePreset.strict5.bytes, "custom starts from what was in effect")
        XCTAssertEqual(selection.customText, "5")
        XCTAssertEqual(selection.customUnit, .mb)

        selection.setCustomText("1.5")
        XCTAssertEqual(selection.targetSizeBytes, 1_500_000)

        selection.select(.preset(.email25))
        XCTAssertEqual(selection.pickerOption, .preset(.email25))
        XCTAssertEqual(selection.targetSizeBytes, TargetSizePreset.email25.bytes)
    }

    func testUnitChangeRescalesTheSameNumber() {
        var selection = TargetSelectionState(mode: .preset(.forms))
        selection.select(.custom)
        selection.setCustomText("800")
        XCTAssertEqual(selection.targetSizeBytes, 800_000_000)
        selection.setCustomUnit(.kb)
        XCTAssertEqual(selection.targetSizeBytes, 800_000)
    }

    func testInvalidCustomInputIsRejectedWithoutClobberingTheTarget() {
        var selection = TargetSelectionState(mode: .preset(.strict5))
        selection.select(.custom)
        selection.setCustomText("2")
        XCTAssertEqual(selection.targetSizeBytes, 2_000_000)

        for garbage in ["abc", "-3", "0", "1,2,3"] {
            selection.setCustomText(garbage)
            XCTAssertEqual(selection.targetSizeBytes, 2_000_000, "\"\(garbage)\" must not change the target")
            XCTAssertNotNil(selection.validationMessage, "\"\(garbage)\" must say why it was ignored")
        }
    }

    func testTinyCustomInputIsRejected() {
        var selection = TargetSelectionState(mode: .preset(.strict5))
        selection.select(.custom)
        selection.setCustomText("1")
        XCTAssertEqual(selection.targetSizeBytes, 1_000_000)

        selection.setCustomUnit(.kb) // 1 KB is a typo, not a target
        XCTAssertEqual(selection.targetSizeBytes, 1_000_000, "the last valid target survives")
        XCTAssertNotNil(selection.validationMessage)
    }

    /// Clearing the field used to leave the last parsed number silently in force.
    func testClearingTheCustomFieldFallsBackExplicitly() {
        var selection = TargetSelectionState(mode: .preset(.veryStrict2))
        selection.select(.custom)
        selection.setCustomText("7")
        XCTAssertEqual(selection.targetSizeBytes, 7_000_000)

        selection.setCustomText("")
        XCTAssertEqual(selection.pickerOption, .preset(.veryStrict2))
        XCTAssertEqual(selection.targetSizeBytes, TargetSizePreset.veryStrict2.bytes)
        XCTAssertNotNil(selection.validationMessage, "the fallback is announced, not silent")
    }

    func testClearingAfterNoLimitReturnsToNoLimit() {
        var selection = TargetSelectionState(mode: .preset(.forms))
        selection.select(.noLimit)
        selection.select(.custom)
        selection.setCustomText("4")
        XCTAssertEqual(selection.targetSizeBytes, 4_000_000)
        selection.setCustomText("")
        XCTAssertNil(selection.targetSizeBytes)
    }

    func testPickerOffersEveryPresetPlusCustomAndNoLimit() {
        let options = TargetPickerOption.allOptions
        XCTAssertEqual(options.count, TargetSizePreset.allCases.count + 2)
        XCTAssertEqual(options.last, .noLimit)
        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
    }

    // MARK: - Try Smaller / Better Quality

    /// The regression these transforms exist for: both buttons called the same
    /// closure with the same input, so they produced identical runs.
    func testTrySmallerAndBetterQualityDivergeFromEachOtherAndFromTheInput() throws {
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = 10_000_000
        settings.qualityMode = .balanced

        let smaller = try XCTUnwrap(settings.trySmaller())
        let better = try XCTUnwrap(settings.betterQuality())

        XCTAssertNotEqual(smaller, settings)
        XCTAssertNotEqual(better, settings)
        XCTAssertNotEqual(smaller, better)
        XCTAssertEqual(smaller.targetSizeBytes, 5_000_000)
        XCTAssertEqual(better.targetSizeBytes, 15_000_000)
        XCTAssertEqual(better.qualityMode, .bestQuality)
        XCTAssertEqual(smaller.qualityMode, .balanced, "with a target to halve, quality is left alone")
    }

    func testWithoutATargetTrySmallerStepsQualityDown() throws {
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = nil
        settings.qualityMode = .bestQuality

        let smaller = try XCTUnwrap(settings.trySmaller())
        XCTAssertNil(smaller.targetSizeBytes)
        XCTAssertEqual(smaller.qualityMode, .balanced)
    }

    func testButtonsDisappearWhenThereIsNowhereLeftToGo() {
        var atTheBottom = CompressionSettings.balanced
        atTheBottom.targetSizeBytes = nil
        atTheBottom.qualityMode = .smallestFile
        XCTAssertFalse(atTheBottom.canTrySmaller)
        XCTAssertNil(atTheBottom.trySmaller())

        var tinyTarget = CompressionSettings.balanced
        tinyTarget.targetSizeBytes = 120_000
        XCTAssertFalse(tinyTarget.canTrySmaller, "halving a 120 KB target is not a request anyone can honour")
        XCTAssertNil(tinyTarget.trySmaller())

        var best = CompressionSettings.balanced
        best.qualityMode = .bestQuality
        XCTAssertFalse(best.canTryBetterQuality)
        XCTAssertNil(best.betterQuality())
    }

    func testQualityNotchesAreOrderedAndTerminate() {
        XCTAssertEqual(QualityMode.bestQuality.oneNotchSmaller, .balanced)
        XCTAssertEqual(QualityMode.balanced.oneNotchSmaller, .smallestFile)
        XCTAssertNil(QualityMode.smallestFile.oneNotchSmaller)
        XCTAssertEqual(QualityMode.smallestFile.oneNotchBetter, .balanced)
        XCTAssertEqual(QualityMode.balanced.oneNotchBetter, .bestQuality)
        XCTAssertNil(QualityMode.bestQuality.oneNotchBetter)
    }

    // MARK: - Result headline

    func testKeptOriginalIsNotPresentedAsAFailure() {
        let result = makeResult(
            targetReached: false,
            reduction: 0,
            warnings: [.keptOriginal]
        )
        let status = ResultStatus.make(result: result, targetSizeBytes: 2_000_000)
        XCTAssertEqual(status, .keptOriginal)
        XCTAssertEqual(status.tone, .neutral)
        XCTAssertFalse(status.title.contains("not reached"))
        XCTAssertEqual(status.systemImage, "checkmark.shield.fill")
    }

    func testNoTargetReportsTheReductionInsteadOfAMissedTarget() {
        let result = makeResult(targetReached: false, reduction: 42, warnings: [])
        let status = ResultStatus.make(result: result, targetSizeBytes: nil)
        XCTAssertEqual(status, .reduced(percent: 42))
        XCTAssertEqual(status.tone, .success)
        XCTAssertFalse(status.title.contains("Target"))
    }

    func testTargetOutcomesStillReadAsBefore() {
        XCTAssertEqual(
            ResultStatus.make(result: makeResult(targetReached: true, reduction: 60, warnings: []), targetSizeBytes: 1_000_000),
            .targetReached
        )
        XCTAssertEqual(
            ResultStatus.make(result: makeResult(targetReached: false, reduction: 10, warnings: []), targetSizeBytes: 1_000_000),
            .targetMissed
        )
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> UserDefaults {
        let name = "target-selection-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func makeResult(
        targetReached: Bool,
        reduction: Double,
        warnings: [CompressionWarning]
    ) -> CompressionResult {
        CompressionResult(
            outputURL: URL(fileURLWithPath: "/tmp/out.jpg"),
            outputFilename: "out.jpg",
            originalSizeBytes: 1_000_000,
            compressedSizeBytes: Int64(1_000_000 * (1 - reduction / 100)),
            targetReached: targetReached,
            reductionPercent: reduction,
            warnings: warnings,
            operationsApplied: [],
            durationSeconds: 0.1
        )
    }
}
