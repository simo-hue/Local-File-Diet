import CoreGraphics
import CoreText
import Foundation
import PDFKit
import XCTest
@testable import LocalFileDiet

/// The rebuild pass replays page content streams, and links, notes, highlights,
/// form fields and the outline all live outside those. These tests are the guard
/// against them quietly disappearing again.
final class PDFInteractiveContentTests: XCTestCase {
    // MARK: - Preservation

    /// The blocker: a photo page and a text page, each carrying annotations, plus
    /// a document outline. Before the fix the output had none of it.
    func testRebuildKeepsLinksNotesHighlightsAndTheOutline() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let originalSize = FileManager.default.fileSize(at: sourceURL)

        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = originalSize / 3

        let run = try await compress(sourceURL, settings: settings)

        XCTAssertLessThan(
            run.result.compressedSizeBytes,
            Int64(Double(originalSize) * 0.7),
            "Preserving the annotations must not cost the compression"
        )
        let document = try XCTUnwrap(PDFDocument(url: run.outputURL))
        XCTAssertEqual(document.pageCount, 3)

        let counts = InteractiveFixtures.annotationCounts(in: document)
        XCTAssertEqual(counts["Link"], 2, "Both links should have survived")
        XCTAssertEqual(counts["Text"], 1, "The note should have survived")
        XCTAssertEqual(counts["Highlight"], 1, "The highlight should have survived")
        XCTAssertEqual(counts["Widget"], 1, "The form field should have survived")

        let urls = InteractiveFixtures.linkTargets(in: document).sorted()
        XCTAssertEqual(urls, ["https://example.com/photo", "https://example.com/terms"])

        let outline = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(outline.numberOfChildren, 2)
        XCTAssertEqual(outline.child(at: 0)?.label, "Photo plate")
        XCTAssertEqual(outline.child(at: 1)?.label, "Agreement")
    }

    /// A rebuilt photo page keeps its annotations too. The engine rebuilds the
    /// page it classifies as a photo, and that page's link used to vanish while
    /// the warning claimed only "rebuilt pages" were at risk.
    func testAnnotationsOnARebuiltPhotoPageSurvive() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let document = try XCTUnwrap(PDFDocument(url: run.outputURL))
        // Page 0 is the photograph, and it was rebuilt: no selectable text left.
        XCTAssertEqual(document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0, 0)
        let onPhotoPage = try XCTUnwrap(document.page(at: 0)?.annotations)
        XCTAssertEqual(
            onPhotoPage.filter { $0.type == "Link" }.first?.url?.absoluteString,
            "https://example.com/photo"
        )
    }

    /// An annotated page carrying `/Rotate 90` keeps that rotation instead of
    /// having it baked into the content, so the annotation needs no transform at
    /// all and lands exactly where it started.
    ///
    /// Baking the turn in was the old behaviour, and it only ever moved
    /// `bounds`. See `testRotatedPageKeepsQuadPointsInkAndAppearanceStreams` for
    /// what that did to everything else the annotation carries.
    func testAnnotatedRotatedPageKeepsItsRotationAndItsAnnotationPosition() async throws {
        let sourceURL = try InteractiveFixtures.rotatedPhotoDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let document = try XCTUnwrap(PDFDocument(url: run.outputURL))
        let page = try XCTUnwrap(document.page(at: 0))
        // The page is still the source's 595 x 842 and still turns a quarter, so
        // a reader shows exactly what it showed before.
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595, accuracy: 1)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 842, accuracy: 1)
        XCTAssertEqual(page.rotation, 90)
        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(annotation.bounds.minX, 100, accuracy: 1)
        XCTAssertEqual(annotation.bounds.minY, 100, accuracy: 1)
        XCTAssertEqual(annotation.bounds.width, 120, accuracy: 1)
        XCTAssertEqual(annotation.bounds.height, 40, accuracy: 1)
    }

    /// The blocker behind the rotation change. `bounds` was the only thing that
    /// followed the page, so on a `/Rotate 90` page a highlight's `/QuadPoints`,
    /// an ink stroke's `/InkList` and a stamp's own `/AP` were all left pointing
    /// somewhere else — measured before the fix, a highlight whose rectangle
    /// rotated correctly to [656 295 676 539] was painted from quad points
    /// [656 315 900 315 656 295 900 295], a band running off an 842-point-wide
    /// page. Every payload now has to come out byte for byte.
    func testRotatedPageKeepsQuadPointsInkAndAppearanceStreams() async throws {
        let sourceURL = try InteractiveFixtures.markupDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let source = try XCTUnwrap(RawPDF.read(sourceURL))
        let output = try XCTUnwrap(RawPDF.read(run.outputURL))
        XCTAssertEqual(output.count, 2)

        // Page 0 is the rotated one, page 1 the upright control. Both have to
        // match the source, and each other.
        for index in 0..<2 {
            let expected = source[index]
            let actual = output[index]
            let side = index == 0 ? "rotated page" : "upright page"
            XCTAssertEqual(actual.rotation, expected.rotation, "\(side) lost its /Rotate")

            let highlight = try XCTUnwrap(actual.annotation("Highlight"), "\(side): no highlight")
            XCTAssertEqual(
                highlight.quadPoints,
                [56, 676, 300, 676, 56, 656, 300, 656],
                "\(side): the highlight is painted from the wrong quad points"
            )
            // Every quad point must land on the page it is drawn on.
            for x in stride(from: 0, to: highlight.quadPoints.count, by: 2) {
                XCTAssertLessThanOrEqual(
                    highlight.quadPoints[x], 595,
                    "\(side): quad point runs off a 595-point-wide page"
                )
            }

            let ink = try XCTUnwrap(actual.annotation("Ink"), "\(side): no ink stroke")
            XCTAssertEqual(
                ink.inkList,
                [110, 110, 150, 180, 200, 130, 290, 190],
                "\(side): the ink stroke moved out from under its own rectangle"
            )
            XCTAssertEqual(ink.rect, [100, 100, 300, 200], "\(side): the ink rectangle moved")

            let stamp = try XCTUnwrap(actual.annotation("Stamp"), "\(side): no stamp")
            XCTAssertEqual(stamp.rect, [350, 500, 500, 600], "\(side): the stamp moved")
            XCTAssertEqual(
                stamp.appearanceBBox, [0, 0, 150, 100],
                "\(side): the stamp's own appearance box was reshaped"
            )
            XCTAssertTrue(
                stamp.appearanceStream.contains("2 2 146 96 re"),
                "\(side): the stamp's artwork was rescaled: \(stamp.appearanceStream.prefix(120))"
            )

            let link = try XCTUnwrap(actual.annotation("Link"), "\(side): no link")
            XCTAssertEqual(link.rect, [56, 60, 300, 88], "\(side): the link moved")
        }
    }

    /// One document with every family on it at once — the shape a real annotated
    /// PDF has, and the one the copy in `interactiveContentPromise` is written
    /// from. Nothing may be dropped, moved or reshaped, and the outline has to
    /// still point at the right pages.
    ///
    /// Measured: 2,027,151 bytes in, 494,467 out, every payload identical — and
    /// 336a82b turned the same file into 500,747 bytes with none of it.
    func testEveryKindOfInteractiveContentSurvivesTogether() async throws {
        let sourceURL = try InteractiveFixtures.everythingDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceSize = FileManager.default.fileSize(at: sourceURL)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = sourceSize / 3

        let run = try await compress(sourceURL, settings: settings)

        XCTAssertLessThanOrEqual(run.result.compressedSizeBytes, sourceSize / 3)
        let source = try XCTUnwrap(RawPDF.read(sourceURL))
        let output = try XCTUnwrap(RawPDF.read(run.outputURL))
        XCTAssertEqual(output.count, 3)

        // Page 0 is the rotated photo page, page 2 the identical upright one.
        // They must match the source AND each other.
        for index in [0, 2] {
            let side = index == 0 ? "rotated page" : "upright page"
            XCTAssertEqual(output[index].rotation, source[index].rotation, "\(side) lost its /Rotate")
            for subtype in ["Highlight", "Ink", "Stamp", "Link", "Text"] {
                let expected = try XCTUnwrap(source[index].annotation(subtype), "\(side): fixture has no \(subtype)")
                let actual = try XCTUnwrap(output[index].annotation(subtype), "\(side): lost the \(subtype)")
                XCTAssertEqual(actual.rect, expected.rect, "\(side): the \(subtype) moved")
                XCTAssertEqual(actual.quadPoints, expected.quadPoints, "\(side): \(subtype) quad points")
                XCTAssertEqual(actual.inkList, expected.inkList, "\(side): \(subtype) ink list")
            }
            // Every quad point still lands on a 595-point-wide page.
            let highlight = try XCTUnwrap(output[index].annotation("Highlight"))
            for position in stride(from: 0, to: highlight.quadPoints.count, by: 2) {
                XCTAssertLessThanOrEqual(highlight.quadPoints[position], 595, "\(side): quad point ran off the page")
            }
            // The stamp keeps its own appearance box and its own artwork. PDFKit
            // re-emits the stream with a clip and named colour spaces around the
            // same operators, so the operators are what is checked.
            let stamp = try XCTUnwrap(output[index].annotation("Stamp"))
            XCTAssertEqual(stamp.appearanceBBox, [0, 0, 150, 100], "\(side): the stamp's appearance box was reshaped")
            XCTAssertTrue(
                stamp.appearanceStream.contains("2 2 146 96 re"),
                "\(side): the stamp's artwork was rescaled: \(stamp.appearanceStream.prefix(120))"
            )
            XCTAssertEqual(
                output[index].annotation("Text")?.contents, "please review",
                "\(side): the sticky note lost its text"
            )
        }

        // The text page keeps its text, its form widget and its answer.
        let document = try XCTUnwrap(PDFDocument(url: run.outputURL))
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)?.string).contains("Clause 1"))
        let widget = try XCTUnwrap(output[1].annotation("Widget"))
        XCTAssertEqual(widget.fieldName, "invoiceTotal")
        XCTAssertEqual(widget.fieldValue, "1234.00")

        let outline = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(outline.numberOfChildren, 3)
        for position in 0..<3 {
            let destination = try XCTUnwrap(outline.child(at: position)?.destination?.page)
            XCTAssertEqual(document.index(for: destination), position, "Bookmark \(position) points at the wrong page")
        }

        // The document-level form dictionary is the one thing that does not come
        // back, which is exactly what `pdfFormFields` says.
        XCTAssertTrue(InteractiveFixtures.contains("/AcroForm", in: try Data(contentsOf: sourceURL)))
        XCTAssertFalse(InteractiveFixtures.contains("/AcroForm", in: try Data(contentsOf: run.outputURL)))
        XCTAssertTrue(run.result.warnings.contains { $0.id == CompressionWarning.pdfFormFields.id })
    }

    /// Internal navigation: a contents page whose links jump to later pages,
    /// including one that gets rebuilt. Rebuilding the document must not send
    /// those links back to page 1.
    func testInternalLinksAndOutlineStillPointAtTheRightPages() async throws {
        let sourceURL = try InteractiveFixtures.documentWithInternalLinks()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let document = try XCTUnwrap(PDFDocument(url: run.outputURL))
        let jumps = try XCTUnwrap(document.page(at: 0)?.annotations)
            .compactMap { ($0.action as? PDFActionGoTo)?.destination.page }
            .map { document.index(for: $0) }
        XCTAssertEqual(jumps.sorted(), [1, 2], "A table of contents must still work")

        let outline = try XCTUnwrap(document.outlineRoot)
        let destination = try XCTUnwrap(outline.child(at: 0)?.destination?.page)
        XCTAssertEqual(document.index(for: destination), 2, "The bookmark must still reach the photo plate")
    }

    // MARK: - Honesty

    /// The rebuild copy used to say links and annotations "may be lost". It has
    /// to describe what the engine now actually does.
    func testRebuildWarningDoesNotClaimAnnotationsAreLost() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let warning = try XCTUnwrap(run.result.warnings.first { $0.id == CompressionWarning.rasterizesPDF.id })
        XCTAssertFalse(
            warning.message.lowercased().contains("may be lost"),
            "The warning still claims annotations are lost: \(warning.message)"
        )
        XCTAssertTrue(
            warning.message.contains("carried over on every page"),
            "The warning should say what survives: \(warning.message)"
        )
    }

    /// A fill-in form field is the one thing that cannot come across whole:
    /// PDFKit will not write the document-level form dictionary into a file it
    /// did not open, so the field arrives read-only. The field itself, its name
    /// and its answer do survive, and the warning has to say exactly that.
    func testFormFieldKeepsItsAnswerAndTheWarningSaysItStopsBeingFillable() async throws {
        let sourceURL = try InteractiveFixtures.formDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let document = try XCTUnwrap(PDFDocument(url: run.outputURL))
        let field = try XCTUnwrap(
            document.page(at: 0)?.annotations.first { $0.type == "Widget" },
            "The form field itself should still be on the page"
        )
        XCTAssertEqual(field.fieldName, "invoiceTotal")
        XCTAssertEqual(field.widgetStringValue, "1234.00")

        let warning = try XCTUnwrap(
            run.result.warnings.first { $0.id == CompressionWarning.pdfFormFields.id },
            "A document with form fields has to be told they stop being fillable"
        )
        XCTAssertTrue(warning.message.contains("cannot be filled in again"), warning.message)

        // The source really did carry a document-level /AcroForm and the output
        // really does not. If a future PDFKit starts writing one, this fails and
        // the warning above should be deleted.
        let sourceBytes = try Data(contentsOf: sourceURL)
        let outputBytes = try Data(contentsOf: run.outputURL)
        XCTAssertTrue(InteractiveFixtures.contains("/AcroForm", in: sourceBytes))
        XCTAssertFalse(InteractiveFixtures.contains("/AcroForm", in: outputBytes))
    }

    /// The release blocker: `OutputGuard` can decide the rebuild did not shrink
    /// the file and hand back the untouched original. The user then holds a
    /// byte-identical copy of their invoice, form and all, while the result
    /// screen asserts specific damage to it.
    func testKeptOriginalWithdrawsEveryClaimAboutTheRebuild() async throws {
        let sourceURL = try InteractiveFixtures.invoiceThatCannotShrink()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceBytes = try Data(contentsOf: sourceURL)
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = Int64(sourceBytes.count) / 2

        let run = try await compress(sourceURL, settings: settings)

        // Precondition: this really is the untouched original.
        let outputBytes = try Data(contentsOf: run.outputURL)
        XCTAssertEqual(outputBytes, sourceBytes)
        XCTAssertTrue(run.result.warnings.contains { $0.id == CompressionWarning.keptOriginal.id })

        let ids = run.result.warnings.map(\.id)
        XCTAssertFalse(
            ids.contains(CompressionWarning.rasterizesPDF.id),
            "Nothing was rebuilt, so nothing may claim pages were: \(ids)"
        )
        XCTAssertFalse(
            ids.contains(CompressionWarning.pdfFormFields.id),
            "The form in this file still works; the app must not say otherwise: \(ids)"
        )
        XCTAssertFalse(ids.contains(CompressionWarning.pdfInteractiveContentLost.id), "\(ids)")
        // And the form really is intact in the bytes the user receives.
        XCTAssertTrue(InteractiveFixtures.contains("/AcroForm", in: outputBytes))
    }

    /// The same rule, one level down and across every engine: a warning that
    /// describes work the guard threw away must not survive it.
    func testWarningsThatDescribeDiscardedWorkAreWithdrawn() {
        let describesWork: [CompressionWarning] = [
            .rasterizesPDF,
            .pdfFormFields,
            .pdfInteractiveContentLost,
            .heicCompatibility,
            .transparencyFlattened,
            .videoPrecision,
            .videoPresetFallback,
            .videoModernCodec,
            .videoOutputPlan(width: 1280, height: 720, codec: "H.264"),
            .zipRepacked,
            .zipCouldNotRepack(.dataDescriptor)
        ]
        for warning in describesWork {
            XCTAssertTrue(warning.describesDiscardedWork, "\(warning.id) describes work that was discarded")
        }

        // These describe the file or the outcome, not the work, so they stay.
        let describesTheFile: [CompressionWarning] = [
            .alreadyOptimized,
            .zipAlreadyCompressed,
            .pdfTextOnly(smallestFileRequested: false),
            .targetMayBeUnrealistic,
            .keptOriginal
        ]
        for warning in describesTheFile {
            XCTAssertFalse(warning.describesDiscardedWork, "\(warning.id) is still true when the original is kept")
        }

        let kept = OutputGuard.warningsAfterKeepingOriginal(
            describesWork + describesTheFile,
            finalSize: 900,
            target: 1_000
        )
        XCTAssertEqual(
            Set(kept.map(\.id)),
            Set([
                CompressionWarning.alreadyOptimized.id,
                CompressionWarning.zipAlreadyCompressed.id,
                "pdfTextOnly",
                CompressionWarning.keptOriginal.id
            ]),
            "Left over: \(kept.map(\.id))"
        )
    }

    /// When the pass that carries the links back fails, the rebuild warning must
    /// stop promising them — otherwise the screen says they were carried over on
    /// every page directly above the warning saying they were not.
    func testAFailedRestoreWithdrawsTheCarryOverPromiseAndNamesFormBoxes() {
        let promised = CompressionWarning.pdfPagesRebuilt(imageDominantPages: 2, of: 3)
        XCTAssertTrue(promised.message.contains("carried over on every page"), promised.message)

        let notPromised = CompressionWarning.pdfPagesRebuilt(
            imageDominantPages: 2,
            of: 3,
            interactiveContentCarried: false
        )
        XCTAssertFalse(
            notPromised.message.contains("carried over"),
            "A failed restore must not leave a promise behind: \(notPromised.message)"
        )
        XCTAssertTrue(notPromised.message.contains("2 of 3"), notPromised.message)
        XCTAssertTrue(notPromised.message.contains("keep their selectable text"), notPromised.message)

        // The same pass carries form widgets, so losing it loses those too.
        let lost = CompressionWarning.pdfInteractiveContentLost
        XCTAssertTrue(lost.message.contains("form boxes"), lost.message)
        // And it must not wander into promising the text. A rebuilt page under
        // the 100-character threshold does lose the few characters it had, and
        // the warning printed beside this one already says which pages kept
        // theirs.
        XCTAssertFalse(
            lost.message.lowercased().contains("text"),
            "This warning is about links and marks, not about text: \(lost.message)"
        )
    }

    /// No warning may be written in a tense that is wrong on the screen it
    /// appears on. Both of these are added before a run AND after one.
    func testWarningsShownBeforeAndAfterARunAreNotWrittenInTheFutureTense() {
        for warning in [
            CompressionWarning.targetMayBeUnrealistic,
            CompressionWarning.videoOutputPlan(width: 1280, height: 720, codec: "H.264")
        ] {
            XCTAssertFalse(
                warning.message.contains("will "),
                "\(warning.id) promises a future on a screen reporting a finished job: \(warning.message)"
            )
            XCTAssertFalse(warning.title.contains("Will "), "\(warning.id): \(warning.title)")
        }
    }

    /// A document with nothing interactive in it must not pick up the form
    /// warning, and must not pay for a rewrite it does not need.
    func testDocumentWithoutInteractiveContentIsNotWarnedAboutForms() async throws {
        let sourceURL = try PDFFixtures.scanDocument(pages: 4)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        XCTAssertFalse(run.result.warnings.contains { $0.id == CompressionWarning.pdfFormFields.id })
        XCTAssertFalse(run.result.warnings.contains { $0.id == CompressionWarning.pdfInteractiveContentLost.id })
    }

    // MARK: - No regressions

    /// Preserving the interactive content is a second pass over the finished
    /// file, so it is the obvious place to accidentally undo the privacy switch.
    func testStripMetadataStillRemovesTheAuthorFromAnAnnotatedDocument() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument(
            attributes: [
                PDFDocumentAttribute.titleAttribute: "Quarterly report",
                PDFDocumentAttribute.authorAttribute: "A Person"
            ]
        )
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        settings.stripMetadata = true
        let stripped = try await compress(sourceURL, settings: settings)
        let strippedAttributes = try XCTUnwrap(PDFDocument(url: stripped.outputURL)?.documentAttributes)
        XCTAssertNil(strippedAttributes[PDFDocumentAttribute.authorAttribute])
        XCTAssertNil(strippedAttributes[PDFDocumentAttribute.titleAttribute])

        settings.stripMetadata = false
        let kept = try await compress(sourceURL, settings: settings)
        let keptAttributes = try XCTUnwrap(PDFDocument(url: kept.outputURL)?.documentAttributes)
        XCTAssertEqual(keptAttributes[PDFDocumentAttribute.authorAttribute] as? String, "A Person")
        XCTAssertEqual(keptAttributes[PDFDocumentAttribute.titleAttribute] as? String, "Quarterly report")
    }

    /// The text page in the annotated fixture still has to come out selectable —
    /// the whole point of not rasterising everything.
    func testTextPagesStillKeepTheirText() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3

        let run = try await compress(sourceURL, settings: settings)

        let text = try XCTUnwrap(PDFDocument(url: run.outputURL)?.page(at: 1)?.string)
        XCTAssertTrue(text.contains("Clause 1"), "The contract page lost its text: \(text.prefix(80))")
    }

    // MARK: - The restore step on its own

    /// A document with nothing interactive in it must come out of the restore
    /// step byte for byte, so the common case pays nothing for this feature.
    func testRestoreLeavesAFileWithNothingToCarryUntouched() throws {
        let sourceURL = try PDFFixtures.textDocument(pages: 3)
        let outputURL = try PDFFixtures.textDocument(pages: 3, at: PDFFixtures.temporaryURL(prefix: "output"))
        let staging = FileManager.default.temporaryDirectory
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        let before = try Data(contentsOf: outputURL)

        let outcome = try PDFInteractiveContent.restore(
            into: outputURL,
            from: sourceURL,
            pages: (0..<3).map { .init(sourcePageIndex: $0, transform: .identity) },
            stagingDirectory: staging
        )

        let after = try Data(contentsOf: outputURL)
        XCTAssertFalse(outcome.carriedAnything)
        XCTAssertFalse(outcome.failed)
        XCTAssertEqual(after, before, "The output was rewritten for nothing")
    }

    /// If the rewrite cannot be written, the output has to be left as the valid
    /// smaller file it already is, and the caller has to hear that the links did
    /// not make it — otherwise the rebuild warning is left promising something
    /// that did not happen.
    func testRestoreReportsFailureAndLeavesTheOutputAloneWhenItCannotWrite() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let run = try await compress(sourceURL, settings: {
            var settings = CompressionSettings.balanced
            settings.targetSizeBytes = FileManager.default.fileSize(at: sourceURL) / 3
            return settings
        }())
        let before = try Data(contentsOf: run.outputURL)

        let outcome = try PDFInteractiveContent.restore(
            into: run.outputURL,
            from: sourceURL,
            pages: (0..<3).map { .init(sourcePageIndex: $0, transform: .identity) },
            stagingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("no-such-directory-\(UUID().uuidString)")
        )

        let after = try Data(contentsOf: run.outputURL)
        XCTAssertTrue(outcome.failed)
        XCTAssertEqual(after, before, "A failed restore must not damage the output")
    }

    /// `copyOutline` recurses once per outline level, and the engine calls
    /// `restore` from an async function, so it runs on a cooperative thread with
    /// a small stack. Measured there with the cap removed, the recursion survived
    /// 1,000 levels and died with SIGBUS at 1,200 in an optimised build (800 and
    /// 1,000 unoptimised), so a hostile bookmark tree takes the app down. The
    /// copy has to stop before that.
    func testDeeplyNestedOutlineIsBoundedInsteadOfOverflowingTheStack() throws {
        let sourceURL = try InteractiveFixtures.deeplyNestedOutlineDocument(depth: 300)
        let outputURL = try PDFFixtures.textDocument(pages: 1, at: PDFFixtures.temporaryURL(prefix: "deep-out"))
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let outcome = try PDFInteractiveContent.restore(
            into: outputURL,
            from: sourceURL,
            pages: [.init(sourcePageIndex: 0, transform: .identity)],
            stagingDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertTrue(outcome.outlineCopied)
        XCTAssertFalse(outcome.failed)

        // The document has to stay alive for the whole walk: a `PDFOutline` does
        // not keep its document up, and a freed one reports no children.
        let written = try XCTUnwrap(PDFDocument(url: outputURL))
        var depth = 0
        var node = written.outlineRoot
        while let current = node, current.numberOfChildren > 0 {
            depth += 1
            node = current.child(at: 0)
        }
        XCTAssertGreaterThan(depth, 1, "The outline should still have been copied")
        XCTAssertLessThanOrEqual(
            depth,
            PDFInteractiveContent.maximumOutlineDepth,
            "The outline copy followed \(depth) levels with no bound"
        )
    }

    // MARK: - Budgeting the restore pass

    /// The restore pass runs after the search has stopped, so its bytes land on
    /// top of a size the search already accepted.
    ///
    /// Measured by running the engine twice over the same fixtures, once with
    /// the pass and once without, at no target so both renders are identical.
    /// The cost is a straight line in the annotation count and does not move
    /// with the document: one photo page whose render is 747,145 bytes cost 839,
    /// 7,074, 35,091, 140,669 and 354,251 bytes for 1, 10, 50, 200 and 500 plain
    /// highlights — about 703 each. Annotations that need a richer appearance
    /// stream cost 11,492, 43,189 and 162,647 for 10, 50 and 200 — a 3.4 KB fixed
    /// part plus about 800 each. Left unbudgeted, three of seven swept targets on
    /// a 211-highlight page came out over the line (400,000 -> 405,231, 425,000
    /// -> 461,205, 525,000 -> 546,437); with the reserve all seven fit.
    func testTheSearchReservesRoomForTheInteractiveContentPass() {
        func profiles(annotations: Int) -> [PDFPageProfile] {
            [PDFPageProfile(
                pageIndex: 0,
                kind: .imageDominant,
                textCharacters: 0,
                imageBytes: 1_000_000,
                imagePixels: 1_000_000,
                annotationCount: annotations,
                hasFormFields: false
            )]
        }

        XCTAssertEqual(
            PDFCompressionEngine.interactiveContentReserve(
                profiles: profiles(annotations: 0),
                hasOutline: false,
                target: 10_000_000
            ),
            0,
            "A document with nothing to carry pays nothing"
        )
        XCTAssertEqual(
            PDFCompressionEngine.interactiveContentReserve(
                profiles: profiles(annotations: 10),
                hasOutline: true,
                target: 10_000_000
            ),
            8_192 + 10 * 1_024
        )
        // The fixed part is not the outline's: ten rich annotations on their own
        // cost 11,492 bytes, which 10 KB of per-annotation budget does not cover.
        XCTAssertEqual(
            PDFCompressionEngine.interactiveContentReserve(
                profiles: profiles(annotations: 10),
                hasOutline: false,
                target: 10_000_000
            ),
            8_192 + 10 * 1_024,
            "The pass has a fixed cost whether or not there is an outline"
        )
        XCTAssertEqual(
            PDFCompressionEngine.interactiveContentReserve(
                profiles: profiles(annotations: 0),
                hasOutline: true,
                target: 10_000_000
            ),
            8_192
        )
        // Never big enough to swallow the picture budget whole.
        XCTAssertEqual(
            PDFCompressionEngine.interactiveContentReserve(
                profiles: profiles(annotations: 10_000),
                hasOutline: true,
                target: 1_000_000
            ),
            250_000
        )
    }

    /// End to end, and the case the reserve exists for: a page carrying enough
    /// annotations that the restore pass is worth more than the slack the search
    /// leaves, aimed at a spread of targets it can all reach.
    ///
    /// Every one of them has to be met. Without the reserve the search stops at
    /// the first render under the target and then the restore pass pushes the
    /// finished file back over: measured, three of these seven missed — 400,000
    /// came out at 405,231, 425,000 at 461,205 and 525,000 at 546,437.
    ///
    /// The floor is measured rather than assumed, because how small a render can
    /// get depends on the machine.
    func testEveryReachableTargetIsStillMetOnceTheAnnotationsAreBackIn() async throws {
        let sourceURL = try InteractiveFixtures.documentWithManyAnnotations(count: 211)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        // An impossible target drives the search to the smallest file it can
        // make, annotations included. Everything above that is reachable.
        var probe = CompressionSettings.balanced
        probe.targetSizeBytes = 1
        let floor = try await compress(sourceURL, settings: probe).result.compressedSizeBytes
        XCTAssertGreaterThan(floor, 0)

        for step in 1...7 {
            let target = floor + Int64(step) * floor / 7
            var settings = CompressionSettings.balanced
            settings.targetSizeBytes = target
            let run = try await compress(sourceURL, settings: settings)
            XCTAssertLessThanOrEqual(
                run.result.compressedSizeBytes,
                target,
                "Target \(target) is above the \(floor)-byte floor, so it was reachable"
            )
            XCTAssertTrue(run.result.targetReached, "target \(target)")
        }
    }

    /// End to end: the finished file, interactive content and all, lands inside
    /// the target rather than just past it.
    func testTheFinishedFileIncludingItsAnnotationsFitsTheTarget() async throws {
        let sourceURL = try InteractiveFixtures.annotatedDocument()
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let target = FileManager.default.fileSize(at: sourceURL) / 3
        var settings = CompressionSettings.balanced
        settings.targetSizeBytes = target

        let run = try await compress(sourceURL, settings: settings)

        XCTAssertLessThanOrEqual(run.result.compressedSizeBytes, target)
        XCTAssertTrue(run.result.targetReached)
        let carried = try XCTUnwrap(PDFDocument(url: run.outputURL)).page(at: 1)?.annotations.count ?? 0
        XCTAssertGreaterThan(
            carried,
            0,
            "It only counts if the annotations are actually in the file that fits"
        )
    }

    // MARK: - Helpers

    /// Runs the engine and hands back the result together with a copy of the
    /// output that only this test can delete.
    ///
    /// `TemporaryFileStore` writes every engine's output into one shared cache
    /// directory, so a tidy-up left running by an earlier test can delete the
    /// file out from under an assertion that reads it. Copying it out first, and
    /// clearing the store before returning, keeps that out of the way.
    private func compress(
        _ url: URL,
        settings: CompressionSettings
    ) async throws -> (result: CompressionResult, outputURL: URL) {
        let store = TemporaryFileStore()
        let engine = PDFCompressionEngine(store: store)
        let result = try await engine.compress(
            input: PDFCompressionEngineTests.makeInput(url: url),
            settings: settings
        ) { _ in }
        let copy = PDFFixtures.temporaryURL(prefix: "output")
        try FileManager.default.copyItem(at: result.outputURL, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        try await store.clearAll()
        return (result, copy)
    }
}

// MARK: - Fixtures

/// Documents that carry the things a content-stream replay cannot see.
enum InteractiveFixtures {
    enum FixtureError: Error { case couldNotWriteDocument }

    /// Page 0: a photograph carrying a link (this page gets rebuilt).
    /// Page 1: a contract page carrying a link, a form field, a note and a
    /// highlight (this page keeps its text).
    /// Page 2: a second photograph, so the document is worth compressing.
    /// Plus a two-entry outline.
    static func annotatedDocument(attributes: [PDFDocumentAttribute: Any] = [:]) throws -> URL {
        let base = PDFFixtures.temporaryURL(prefix: "annotated-base")
        defer { try? FileManager.default.removeItem(at: base) }
        let writer = try PDFPageWriter(url: base, documentInfo: [kCGPDFContextCreator: "Fixture"])
        let first = try PDFFixtures.photograph(seed: 7)
        let second = try PDFFixtures.photograph(seed: 19)
        writer.writePage(mediaBox: PDFFixtures.pageBox) { $0.draw(first, in: PDFFixtures.pageBox) }
        writer.writePage(mediaBox: PDFFixtures.pageBox) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(PDFFixtures.pageBox)
            drawContract(in: context)
        }
        writer.writePage(mediaBox: PDFFixtures.pageBox) { $0.draw(second, in: PDFFixtures.pageBox) }
        writer.finish()

        guard let document = PDFDocument(url: base) else { throw FixtureError.couldNotWriteDocument }
        if let photo = document.page(at: 0) {
            photo.addAnnotation(link(to: "https://example.com/photo", at: CGRect(x: 40, y: 40, width: 200, height: 20)))
        }
        guard let contract = document.page(at: 1) else { throw FixtureError.couldNotWriteDocument }
        contract.addAnnotation(link(to: "https://example.com/terms", at: CGRect(x: 56, y: 700, width: 300, height: 18)))

        let field = PDFAnnotation(bounds: CGRect(x: 56, y: 600, width: 220, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "signature"
        field.widgetStringValue = "typed name"
        contract.addAnnotation(field)

        let note = PDFAnnotation(bounds: CGRect(x: 400, y: 640, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "please review"
        contract.addAnnotation(note)

        let highlight = PDFAnnotation(bounds: CGRect(x: 56, y: 660, width: 200, height: 16), forType: .highlight, withProperties: nil)
        contract.addAnnotation(highlight)

        let root = PDFOutline()
        root.insertChild(entry("Photo plate", to: document.page(at: 0)), at: 0)
        root.insertChild(entry("Agreement", to: contract), at: 1)
        document.outlineRoot = root
        if !attributes.isEmpty {
            document.documentAttributes = attributes
        }

        let url = PDFFixtures.temporaryURL(prefix: "annotated")
        guard document.write(to: url) else { throw FixtureError.couldNotWriteDocument }
        return url
    }

    /// One photograph on a page marked `/Rotate 90`, carrying one annotation.
    static func rotatedPhotoDocument() throws -> URL {
        let base = PDFFixtures.temporaryURL(prefix: "rotated-base")
        defer { try? FileManager.default.removeItem(at: base) }
        let writer = try PDFPageWriter(url: base, documentInfo: [:])
        let photo = try PDFFixtures.photograph(seed: 23)
        writer.writePage(mediaBox: PDFFixtures.pageBox) { $0.draw(photo, in: PDFFixtures.pageBox) }
        writer.finish()

        guard let document = PDFDocument(url: base), let page = document.page(at: 0) else {
            throw FixtureError.couldNotWriteDocument
        }
        page.rotation = 90
        let stamp = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 120, height: 40), forType: .square, withProperties: nil)
        page.addAnnotation(stamp)

        let url = PDFFixtures.temporaryURL(prefix: "rotated")
        guard document.write(to: url) else { throw FixtureError.couldNotWriteDocument }
        return url
    }

    /// A contents page whose links jump to a text page and to a photo page.
    static func documentWithInternalLinks() throws -> URL {
        let base = PDFFixtures.temporaryURL(prefix: "toc-base")
        defer { try? FileManager.default.removeItem(at: base) }
        let writer = try PDFPageWriter(url: base, documentInfo: [:])
        for index in 0..<2 {
            writer.writePage(mediaBox: PDFFixtures.pageBox) { context in
                context.setFillColor(gray: 1, alpha: 1)
                context.fill(PDFFixtures.pageBox)
                draw(PDFFixtures.lines(for: index), in: context)
            }
        }
        let photo = try PDFFixtures.photograph(seed: 31)
        writer.writePage(mediaBox: PDFFixtures.pageBox) { $0.draw(photo, in: PDFFixtures.pageBox) }
        writer.finish()

        guard let document = PDFDocument(url: base), let contents = document.page(at: 0) else {
            throw FixtureError.couldNotWriteDocument
        }
        for (offset, target) in [1, 2].enumerated() {
            guard let destination = document.page(at: target) else { continue }
            let jump = PDFAnnotation(
                bounds: CGRect(x: 56, y: CGFloat(400 - offset * 30), width: 250, height: 18),
                forType: .link,
                withProperties: nil
            )
            jump.action = PDFActionGoTo(destination: PDFDestination(page: destination, at: CGPoint(x: 0, y: 700)))
            contents.addAnnotation(jump)
        }
        let root = PDFOutline()
        root.insertChild(entry("Photo plate", to: document.page(at: 2)), at: 0)
        document.outlineRoot = root

        let url = PDFFixtures.temporaryURL(prefix: "toc")
        guard document.write(to: url) else { throw FixtureError.couldNotWriteDocument }
        return url
    }

    /// A PDF written by hand so it carries a real document-level `/AcroForm`,
    /// the way Acrobat writes one. PDFKit never produces this shape itself, and
    /// it is the thing the rebuild provably cannot hand back.
    static func formDocument() throws -> URL {
        let url = PDFFixtures.temporaryURL(prefix: "form")
        let content = """
        BT /F1 14 Tf 56 760 Td (INVOICE FORM - please fill in the box below and sign.) Tj ET
        BT /F1 14 Tf 56 730 Td (This paragraph is here so the page counts as a text page.) Tj ET
        BT /F1 14 Tf 56 700 Td (Terms and conditions apply, see the linked page for details.) Tj ET
        """
        let objects: [String] = [
            "1 0 obj\n<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R] /DA (/Helv 0 Tf 0 g) /NeedAppearances true >> >>\nendobj\n",
            "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
            "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R /Annots [6 0 R 7 0 R] >>\nendobj\n",
            "4 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n",
            "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
            "6 0 obj\n<< /Type /Annot /Subtype /Widget /FT /Tx /T (invoiceTotal) /V (1234.00) /Rect [56 600 276 624] /F 4 /DA (/Helv 12 Tf 0 g) /P 3 0 R >>\nendobj\n",
            "7 0 obj\n<< /Type /Annot /Subtype /Link /Rect [56 694 400 712] /Border [0 0 0] /A << /Type /Action /S /URI /URI (https://example.com/terms) >> >>\nendobj\n"
        ]
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for object in objects {
            offsets.append(pdf.utf8.count)
            pdf += object
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(pdf.utf8).write(to: url)

        // The form page is text, so on its own there is nothing to rebuild. A
        // photo page gives the engine a reason to run.
        guard let document = PDFDocument(url: url) else { throw FixtureError.couldNotWriteDocument }
        let photoURL = PDFFixtures.temporaryURL(prefix: "form-photo")
        defer { try? FileManager.default.removeItem(at: photoURL) }
        let writer = try PDFPageWriter(url: photoURL, documentInfo: [:])
        let photo = try PDFFixtures.photograph(seed: 42)
        writer.writePage(mediaBox: PDFFixtures.pageBox) { $0.draw(photo, in: PDFFixtures.pageBox) }
        writer.finish()
        guard let page = PDFDocument(url: photoURL)?.page(at: 0) else { throw FixtureError.couldNotWriteDocument }
        document.insert(page, at: 1)
        guard document.write(to: url) else { throw FixtureError.couldNotWriteDocument }
        return url
    }

    // MARK: Hand-written documents

    /// PDFKit normalises `/QuadPoints`, `/InkList` and `/AP` on its way out, so
    /// a fixture built through `PDFAnnotation` cannot prove what the engine did
    /// with them. These are written as literal PDF objects instead.
    ///
    /// Page 0: a photograph on a `/Rotate 90` page.
    /// Page 1: the same photograph upright, as the control.
    /// Both carry a highlight with quad points, an ink stroke with an ink list,
    /// a stamp with its own appearance stream, and a link — at identical
    /// coordinates, so the two pages must come out identical to each other.
    static func markupDocument() throws -> URL {
        var pdf = RawPDFBuilder()
        let pages = pdf.reserve()
        let appearance = pdf.add(
            "<< /Type /XObject /Subtype /Form /BBox [0 0 150 100] /Resources << >> /Length 47 >>",
            stream: Data("1 0 0 RG 4 w 2 2 146 96 re S 2 2 m 148 98 l S".utf8)
        )

        var kids: [Int] = []
        for seed in [11, 29] as [UInt64] {
            let jpeg = try PDFImageEncoder.jpegData(
                PDFFixtures.photograph(seed: seed, width: 1_240, height: 1_754),
                quality: 0.9
            )
            let image = pdf.add(
                "<< /Type /XObject /Subtype /Image /Width 1240 /Height 1754 /ColorSpace /DeviceRGB "
                    + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>",
                stream: jpeg
            )
            let drawing = "q 595 0 0 842 0 0 cm /Im Do Q"
            let contents = pdf.add("<< /Length \(drawing.utf8.count) >>", stream: Data(drawing.utf8))
            let page = pdf.reserve()
            let highlight = pdf.add(
                "<< /Type /Annot /Subtype /Highlight /Rect [56 656 300 676] "
                    + "/QuadPoints [56 676 300 676 56 656 300 656] /C [1 1 0] /CA 0.4 /P \(page) 0 R >>")
            let ink = pdf.add(
                "<< /Type /Annot /Subtype /Ink /Rect [100 100 300 200] "
                    + "/InkList [[110 110 150 180 200 130 290 190]] /C [0 0 1] /BS << /W 3 >> /P \(page) 0 R >>")
            let stamp = pdf.add(
                "<< /Type /Annot /Subtype /Stamp /Rect [350 500 500 600] /Name /Approved "
                    + "/AP << /N \(appearance) 0 R >> /P \(page) 0 R >>")
            let link = pdf.add(
                "<< /Type /Annot /Subtype /Link /Rect [56 60 300 88] /Border [0 0 0] "
                    + "/A << /Type /Action /S /URI /URI (https://example.com/mark) >> /P \(page) 0 R >>")
            pdf.fill(
                page,
                "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                    + (kids.isEmpty ? "/Rotate 90 " : "")
                    + "/Resources << /XObject << /Im \(image) 0 R >> >> /Contents \(contents) 0 R "
                    + "/Annots [\(highlight) 0 R \(ink) 0 R \(stamp) 0 R \(link) 0 R] >>"
            )
            kids.append(page)
        }
        pdf.fill(pages, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count 2 >>")
        pdf.fillCatalog("<< /Type /Catalog /Pages \(pages) 0 R >>")

        let url = PDFFixtures.temporaryURL(prefix: "markup")
        try pdf.data().write(to: url)
        return url
    }

    /// Everything at once, written as literal PDF objects.
    ///
    /// Page 0: a photograph on a `/Rotate 90` page. Page 1: a text page. Page 2:
    /// the same photograph upright, as page 0's control. Both photo pages carry a
    /// highlight with `/QuadPoints`, an ink stroke with `/InkList`, a stamp with
    /// its own `/AP`, a link and a sticky note, at identical coordinates. The
    /// text page carries a fill-in form widget with a real document-level
    /// `/AcroForm`, a link and a highlight. Plus one bookmark per page.
    static func everythingDocument() throws -> URL {
        var pdf = RawPDFBuilder()
        let pages = pdf.reserve()
        let outlines = pdf.reserve()
        let font = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let appearance = pdf.add(
            "<< /Type /XObject /Subtype /Form /BBox [0 0 150 100] /Resources << >> /Length 47 >>",
            stream: Data("1 0 0 RG 4 w 2 2 146 96 re S 2 2 m 148 98 l S".utf8)
        )

        func photoPage(seed: UInt64, rotated: Bool) throws -> Int {
            let jpeg = try PDFImageEncoder.jpegData(
                PDFFixtures.photograph(seed: seed, width: 1_240, height: 1_754),
                quality: 0.9
            )
            let image = pdf.add(
                "<< /Type /XObject /Subtype /Image /Width 1240 /Height 1754 /ColorSpace /DeviceRGB "
                    + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>",
                stream: jpeg
            )
            let drawing = "q 595 0 0 842 0 0 cm /Im Do Q"
            let contents = pdf.add("<< /Length \(drawing.utf8.count) >>", stream: Data(drawing.utf8))
            let page = pdf.reserve()
            let highlight = pdf.add(
                "<< /Type /Annot /Subtype /Highlight /Rect [56 656 300 676] "
                    + "/QuadPoints [56 676 300 676 56 656 300 656] /C [1 1 0] /CA 0.4 /P \(page) 0 R >>")
            let ink = pdf.add(
                "<< /Type /Annot /Subtype /Ink /Rect [100 100 300 200] "
                    + "/InkList [[110 110 150 180 200 130 290 190]] /C [0 0 1] /BS << /W 3 >> /P \(page) 0 R >>")
            let stamp = pdf.add(
                "<< /Type /Annot /Subtype /Stamp /Rect [350 500 500 600] /Name /Approved "
                    + "/AP << /N \(appearance) 0 R >> /P \(page) 0 R >>")
            let link = pdf.add(
                "<< /Type /Annot /Subtype /Link /Rect [56 60 300 88] /Border [0 0 0] "
                    + "/A << /Type /Action /S /URI /URI (https://example.com/mark) >> /P \(page) 0 R >>")
            let note = pdf.add(
                "<< /Type /Annot /Subtype /Text /Rect [400 700 424 724] /Contents (please review) "
                    + "/Name /Comment /P \(page) 0 R >>")
            pdf.fill(
                page,
                "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                    + (rotated ? "/Rotate 90 " : "")
                    + "/Resources << /XObject << /Im \(image) 0 R >> >> /Contents \(contents) 0 R "
                    + "/Annots [\(highlight) 0 R \(ink) 0 R \(stamp) 0 R \(link) 0 R \(note) 0 R] >>"
            )
            return page
        }

        let rotatedPhoto = try photoPage(seed: 11, rotated: true)

        let body = """
        BT /F1 14 Tf 56 780 Td (AGREEMENT - page 2 of the fixture.) Tj ET
        BT /F1 14 Tf 56 756 Td (Clause 1: the parties agree to the terms set out on the linked page.) Tj ET
        BT /F1 14 Tf 56 732 Td (Clause 2: fill in the total in the box below and sign it.) Tj ET
        BT /F1 14 Tf 56 708 Td (See https://example.com/terms for the full text of this agreement.) Tj ET
        """
        let textStream = pdf.add("<< /Length \(body.utf8.count) >>", stream: Data(body.utf8))
        let textPage = pdf.reserve()
        let widget = pdf.add(
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (invoiceTotal) /V (1234.00) /Rect [56 600 276 624] "
                + "/F 4 /DA (/Helv 12 Tf 0 g) /P \(textPage) 0 R >>")
        let textLink = pdf.add(
            "<< /Type /Annot /Subtype /Link /Rect [56 700 400 718] /Border [0 0 0] "
                + "/A << /Type /Action /S /URI /URI (https://example.com/terms) >> /P \(textPage) 0 R >>")
        let textHighlight = pdf.add(
            "<< /Type /Annot /Subtype /Highlight /Rect [56 748 400 768] "
                + "/QuadPoints [56 768 400 768 56 748 400 748] /C [1 1 0] /CA 0.4 /P \(textPage) 0 R >>")
        pdf.fill(
            textPage,
            "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                + "/Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(textStream) 0 R "
                + "/Annots [\(widget) 0 R \(textLink) 0 R \(textHighlight) 0 R] >>"
        )

        let uprightPhoto = try photoPage(seed: 29, rotated: false)
        let kids = [rotatedPhoto, textPage, uprightPhoto]
        pdf.fill(pages, "<< /Type /Pages /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] /Count 3 >>")

        let labels = ["Rotated plate", "Agreement", "Upright plate"]
        let chain = kids.map { _ in pdf.reserve() }
        for (index, node) in chain.enumerated() {
            var entry = "<< /Title (\(labels[index])) /Parent \(outlines) 0 R"
            if index > 0 { entry += " /Prev \(chain[index - 1]) 0 R" }
            if index + 1 < chain.count { entry += " /Next \(chain[index + 1]) 0 R" }
            entry += " /Dest [\(kids[index]) 0 R /XYZ 0 800 0] >>"
            pdf.fill(node, entry)
        }
        pdf.fill(
            outlines,
            "<< /Type /Outlines /First \(chain[0]) 0 R /Last \(chain[chain.count - 1]) 0 R /Count \(chain.count) >>"
        )
        pdf.fillCatalog(
            "<< /Type /Catalog /Pages \(pages) 0 R /Outlines \(outlines) 0 R "
                + "/AcroForm << /Fields [\(widget) 0 R] /DA (/Helv 0 Tf 0 g) /NeedAppearances true >> >>"
        )

        let url = PDFFixtures.temporaryURL(prefix: "everything")
        try pdf.data().write(to: url)
        return url
    }

    /// An invoice with a real `/AcroForm` field and one photo page that is
    /// already compressed harder than the engine can re-compress it. The rebuild
    /// therefore comes out BIGGER and `OutputGuard` hands the original back.
    static func invoiceThatCannotShrink() throws -> URL {
        // 620 x 877 at quality 0.05: far fewer bytes than any honest re-render at
        // the engine's DPI, and still enough pixels to read as a photo page.
        let jpeg = try PDFImageEncoder.jpegData(
            PDFFixtures.photograph(seed: 5, width: 620, height: 877),
            quality: 0.05
        )
        let text = """
        BT /F1 14 Tf 56 760 Td (INVOICE 2024-118 - please fill in the total below and sign it.) Tj ET
        BT /F1 14 Tf 56 730 Td (Payment terms are thirty days from the date of issue above.) Tj ET
        """
        var pdf = RawPDFBuilder()
        let pages = pdf.reserve()
        let font = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let image = pdf.add(
            "<< /Type /XObject /Subtype /Image /Width 620 /Height 877 /ColorSpace /DeviceRGB "
                + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>",
            stream: jpeg
        )
        let textStream = pdf.add("<< /Length \(text.utf8.count) >>", stream: Data(text.utf8))
        let drawing = "q 595 0 0 842 0 0 cm /Im Do Q"
        let photoStream = pdf.add("<< /Length \(drawing.utf8.count) >>", stream: Data(drawing.utf8))
        let formPage = pdf.reserve()
        let photoPage = pdf.reserve()
        let widget = pdf.add(
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (total) /V () /Rect [56 600 276 624] "
                + "/F 4 /DA (/Helv 12 Tf 0 g) /P \(formPage) 0 R >>")
        pdf.fill(
            formPage,
            "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                + "/Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(textStream) 0 R "
                + "/Annots [\(widget) 0 R] >>"
        )
        pdf.fill(
            photoPage,
            "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                + "/Resources << /XObject << /Im \(image) 0 R >> >> /Contents \(photoStream) 0 R >>"
        )
        pdf.fill(pages, "<< /Type /Pages /Kids [\(formPage) 0 R \(photoPage) 0 R] /Count 2 >>")
        pdf.fillCatalog(
            "<< /Type /Catalog /Pages \(pages) 0 R /AcroForm << /Fields [\(widget) 0 R] "
                + "/DA (/Helv 0 Tf 0 g) /NeedAppearances true >> >>"
        )

        let url = PDFFixtures.temporaryURL(prefix: "invoice")
        try pdf.data().write(to: url)
        return url
    }

    /// One photo page carrying `count` highlights, for the case where the
    /// restore pass costs more than the slack the search leaves behind it.
    static func documentWithManyAnnotations(count: Int) throws -> URL {
        var pdf = RawPDFBuilder()
        let pages = pdf.reserve()
        let jpeg = try PDFImageEncoder.jpegData(
            PDFFixtures.photograph(seed: 5, width: 1_240, height: 1_754),
            quality: 0.9
        )
        let image = pdf.add(
            "<< /Type /XObject /Subtype /Image /Width 1240 /Height 1754 /ColorSpace /DeviceRGB "
                + "/BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>",
            stream: jpeg
        )
        let drawing = "q 595 0 0 842 0 0 cm /Im Do Q"
        let contents = pdf.add("<< /Length \(drawing.utf8.count) >>", stream: Data(drawing.utf8))
        let page = pdf.reserve()
        let annotations = (0..<count).map { index -> Int in
            let y = 40 + (index % 38) * 20
            return pdf.add(
                "<< /Type /Annot /Subtype /Highlight /Rect [56 \(y) 300 \(y + 16)] "
                    + "/QuadPoints [56 \(y + 16) 300 \(y + 16) 56 \(y) 300 \(y)] /C [1 1 0] /CA 0.4 "
                    + "/P \(page) 0 R >>")
        }
        let annots = annotations.isEmpty
            ? ""
            : "/Annots [\(annotations.map { "\($0) 0 R" }.joined(separator: " "))] "
        pdf.fill(
            page,
            "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                + "/Resources << /XObject << /Im \(image) 0 R >> >> /Contents \(contents) 0 R "
                + annots + ">>"
        )
        pdf.fill(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")
        pdf.fillCatalog("<< /Type /Catalog /Pages \(pages) 0 R >>")

        let url = PDFFixtures.temporaryURL(prefix: "many-annots")
        try pdf.data().write(to: url)
        return url
    }

    /// One page and a bookmark chain nested `depth` levels deep, which is the
    /// shape that used to take the stack down with it.
    static func deeplyNestedOutlineDocument(depth: Int) throws -> URL {
        var pdf = RawPDFBuilder()
        let pages = pdf.reserve()
        let outlines = pdf.reserve()
        let page = pdf.reserve()
        let body = "BT /F1 14 Tf 56 760 Td (A page for the bookmarks to point at.) Tj ET"
        let font = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let contents = pdf.add("<< /Length \(body.utf8.count) >>", stream: Data(body.utf8))
        pdf.fill(
            page,
            "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 595 842] "
                + "/Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(contents) 0 R >>"
        )
        pdf.fill(pages, "<< /Type /Pages /Kids [\(page) 0 R] /Count 1 >>")

        // Reserve the whole chain first so each node can name its child. Each
        // node needs /First, /Last AND a positive /Count, or PDFKit reports it
        // as a leaf and the nesting this test is about never reaches the copy.
        let chain = (0..<depth).map { _ in pdf.reserve() }
        for (level, node) in chain.enumerated() {
            let parent = level == 0 ? outlines : chain[level - 1]
            let descendants = chain.count - 1 - level
            let child = descendants > 0
                ? " /First \(chain[level + 1]) 0 R /Last \(chain[level + 1]) 0 R /Count \(descendants)"
                : ""
            pdf.fill(
                node,
                "<< /Title (Level \(level)) /Parent \(parent) 0 R\(child) /Dest [\(page) 0 R /XYZ 0 800 0] >>"
            )
        }
        pdf.fill(
            outlines,
            "<< /Type /Outlines /First \(chain[0]) 0 R /Last \(chain[0]) 0 R /Count \(chain.count) >>"
        )
        pdf.fillCatalog("<< /Type /Catalog /Pages \(pages) 0 R /Outlines \(outlines) 0 R >>")

        let url = PDFFixtures.temporaryURL(prefix: "deep-outline")
        try pdf.data().write(to: url)
        return url
    }

    // MARK: Reading the result

    static func annotationCounts(in document: PDFDocument) -> [String: Int] {
        var counts: [String: Int] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                counts[annotation.type ?? "?", default: 0] += 1
            }
        }
        return counts
    }

    static func linkTargets(in document: PDFDocument) -> [String] {
        var targets: [String] = []
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let url = annotation.url { targets.append(url.absoluteString) }
            }
        }
        return targets
    }

    static func contains(_ marker: String, in data: Data) -> Bool {
        data.range(of: Data(marker.utf8)) != nil
    }

    // MARK: Building

    private static func link(to string: String, at bounds: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.url = URL(string: string)
        return annotation
    }

    private static func entry(_ label: String, to page: PDFPage?) -> PDFOutline {
        let outline = PDFOutline()
        outline.label = label
        if let page {
            outline.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 800))
        }
        return outline
    }

    private static func drawContract(in context: CGContext) {
        draw([
            "AGREEMENT - page 2",
            "Clause 1: the parties agree to the terms set out on the linked page.",
            "Clause 2: signature required below.",
            "See https://example.com/terms for the full text of this agreement."
        ], in: context)
    }

    /// Real text operators, so `PDFPage.string` can prove the page was not
    /// rasterised. `PDFFixtures` draws its pages the same way but keeps the
    /// helper to itself.
    private static func draw(_ lines: [String], in context: CGContext) {
        let box = PDFFixtures.pageBox
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        var y = box.maxY - 64
        for text in lines {
            guard y > box.minY + 48 else { break }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            context.textPosition = CGPoint(x: box.minX + 56, y: y)
            CTLineDraw(line, context)
            y -= 22
        }
    }
}

// MARK: - Writing PDF objects by hand

/// A minimum-effort PDF writer for fixtures whose exact object bytes matter.
///
/// PDFKit is the wrong tool for building these: it rewrites `/QuadPoints`,
/// regenerates `/AP` and will not emit an `/AcroForm` at all, which are the
/// three things these fixtures exist to pin down. Object 1 is always the
/// catalog, so `/Root 1 0 R` is stable.
struct RawPDFBuilder {
    private var bodies: [String] = [""]
    private var streams: [Data?] = [nil]

    /// Books an object number whose body is written later, for the forward
    /// references a page tree and an outline chain both need.
    mutating func reserve() -> Int {
        bodies.append("")
        streams.append(nil)
        return bodies.count
    }

    @discardableResult
    mutating func add(_ body: String, stream: Data? = nil) -> Int {
        let number = reserve()
        bodies[number - 1] = body
        streams[number - 1] = stream
        return number
    }

    mutating func fill(_ number: Int, _ body: String) {
        bodies[number - 1] = body
    }

    mutating func fillCatalog(_ body: String) {
        bodies[0] = body
    }

    func data() -> Data {
        var out = Data("%PDF-1.6\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n\(body)\n".utf8))
            if let stream = streams[index] {
                out.append(Data("stream\n".utf8))
                out.append(stream)
                out.append(Data("\nendstream\n".utf8))
            }
            out.append(Data("endobj\n".utf8))
        }
        let startxref = out.count
        out.append(Data("xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        out.append(Data(
            "trailer\n<< /Size \(bodies.count + 1) /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n".utf8
        ))
        return out
    }
}

// MARK: - Reading PDF objects back

/// Reads annotations at the object level. `PDFAnnotation` hides exactly the
/// fields these tests are about, so the assertions read the dictionary itself.
enum RawPDF {
    struct Annotation {
        var subtype = ""
        var rect: [Double] = []
        var quadPoints: [Double] = []
        var inkList: [Double] = []
        var appearanceBBox: [Double] = []
        var appearanceStream = ""
        /// A sticky note's text, and a form widget's name and current answer.
        /// `PDFAnnotation` reports these too, but reading them here keeps one
        /// view of the file rather than two.
        var contents = ""
        var fieldName = ""
        var fieldValue = ""
    }

    struct Page {
        var rotation = 0
        var annotations: [Annotation] = []

        func annotation(_ subtype: String) -> Annotation? {
            annotations.first { $0.subtype == subtype }
        }
    }

    static func read(_ url: URL) -> [Page]? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else { return nil }
        var pages: [Page] = []
        for number in 1...document.numberOfPages {
            guard let source = document.page(at: number), let dictionary = source.dictionary else { continue }
            var page = Page()
            var rotation: CGPDFInteger = 0
            CGPDFDictionaryGetInteger(dictionary, "Rotate", &rotation)
            page.rotation = ((Int(rotation) % 360) + 360) % 360

            var annotations: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations {
                for index in 0..<CGPDFArrayGetCount(annotations) {
                    var entry: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(annotations, index, &entry), let entry else { continue }
                    page.annotations.append(annotation(in: entry))
                }
            }
            pages.append(page)
        }
        return pages
    }

    private static func annotation(in dictionary: CGPDFDictionaryRef) -> Annotation {
        var annotation = Annotation()
        var subtype: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype {
            annotation.subtype = String(cString: subtype)
        }
        annotation.rect = numbers(dictionary, "Rect")
        annotation.quadPoints = numbers(dictionary, "QuadPoints")
        annotation.contents = string(dictionary, "Contents")
        annotation.fieldName = string(dictionary, "T")
        annotation.fieldValue = string(dictionary, "V")
        // /InkList is an array of stroke arrays; the fixtures use one stroke.
        var inkList: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "InkList", &inkList), let inkList,
           CGPDFArrayGetCount(inkList) > 0 {
            var stroke: CGPDFArrayRef?
            if CGPDFArrayGetArray(inkList, 0, &stroke), let stroke {
                annotation.inkList = numbers(in: stroke)
            }
        }
        var appearance: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "AP", &appearance), let appearance {
            var normal: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(appearance, "N", &normal), let normal {
                if let streamDictionary = CGPDFStreamGetDictionary(normal) {
                    annotation.appearanceBBox = numbers(streamDictionary, "BBox")
                }
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(normal, &format) {
                    annotation.appearanceStream = String(decoding: data as Data, as: UTF8.self)
                }
            }
        }
        return annotation
    }

    private static func string(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(dictionary, key, &value), let value,
              let text = CGPDFStringCopyTextString(value) else { return "" }
        return text as String
    }

    private static func numbers(_ dictionary: CGPDFDictionaryRef, _ key: String) -> [Double] {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array else { return [] }
        return numbers(in: array)
    }

    private static func numbers(in array: CGPDFArrayRef) -> [Double] {
        var values: [Double] = []
        for index in 0..<CGPDFArrayGetCount(array) {
            var real: CGPDFReal = 0
            if CGPDFArrayGetNumber(array, index, &real) {
                values.append(Double(real))
                continue
            }
            var integer: CGPDFInteger = 0
            if CGPDFArrayGetInteger(array, index, &integer) {
                values.append(Double(integer))
            }
        }
        return values
    }
}
