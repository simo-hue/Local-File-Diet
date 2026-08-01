import XCTest
@testable import LocalFileDiet

/// Guards the build inputs that decide whether the app can be submitted at all:
/// the privacy manifest App Store Connect validates at processing time, and the
/// share extension's activation rule. Both are plists, so nothing in the Swift
/// compiler notices when they drift away from the code they describe.
final class AppStoreSubmissionTests: XCTestCase {

    // MARK: - Repository access

    /// The manifest and the activation rule are build inputs, not runtime
    /// resources, so the checks read them from the source tree rather than from
    /// a test bundle.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func plist(at relativePath: String) throws -> [String: Any] {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(parsed as? [String: Any], "\(relativePath) is not a dictionary")
    }

    private func sourceText(under relativeDirectory: String) throws -> [String: String] {
        let root = Self.repositoryRoot.appendingPathComponent(relativeDirectory)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var files: [String: String] = [:]
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files[url.lastPathComponent] = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertFalse(files.isEmpty, "found no Swift sources under \(relativeDirectory)")
        return files
    }

    // MARK: - Required-reason API categories

    /// Symbols that put a binary into one of Apple's required-reason API
    /// categories. Anything matched here has to appear in the manifest, or the
    /// upload is rejected at processing with ITMS-91053.
    private static let categoryTriggers: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "contentModificationDateKey", "creationDateKey",
            ".modificationDate", ".creationDate",
            "NSFileModificationDate", "NSFileCreationDate",
            "getattrlist", "fstat(", "lstat("
        ],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            "volumeAvailableCapacity", "VolumeAvailableCapacity",
            "systemFreeSize", "NSFileSystemFreeSize",
            "attributesOfFileSystem", "statfs"
        ],
        "NSPrivacyAccessedAPICategorySystemBootTime": [
            "systemUptime", "mach_absolute_time", "mach_continuous_time", "kern.boottime"
        ],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": [
            "activeInputModes", "UITextInputMode"
        ],
        "NSPrivacyAccessedAPICategoryUserDefaults": [
            "UserDefaults", "@AppStorage", "@SceneStorage"
        ]
    ]

    /// Apple accepts only these reason codes per category. A typo here is a
    /// second rejection cycle, not a warning.
    private static let allowedReasons: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
        "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1", "8FFB.1", "3D61.1"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"]
    ]

    private func triggeredCategories(in sources: [String: String]) -> [String: [String]] {
        var hits: [String: [String]] = [:]
        for (category, needles) in Self.categoryTriggers {
            for (filename, text) in sources {
                for needle in needles where text.contains(needle) {
                    hits[category, default: []].append("\(filename): \(needle)")
                }
            }
        }
        return hits
    }

    private func declaredCategories() throws -> [String: Set<String>] {
        let manifest = try plist(at: "LocalFileDiet/Resources/PrivacyInfo.xcprivacy")
        let entries = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "PrivacyInfo.xcprivacy has no NSPrivacyAccessedAPITypes array"
        )
        var declared: [String: Set<String>] = [:]
        for entry in entries {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            let reasons = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            declared[type] = Set(reasons)
        }
        return declared
    }

    func testPrivacyManifestDeclaresEveryCategoryTheAppBinaryTriggers() throws {
        let declared = try declaredCategories()
        let triggered = triggeredCategories(in: try sourceText(under: "LocalFileDiet"))

        for (category, evidence) in triggered {
            XCTAssertNotNil(
                declared[category],
                "\(category) is used by \(evidence.joined(separator: ", ")) but is not declared in PrivacyInfo.xcprivacy"
            )
        }
    }

    func testPrivacyManifestDeclaresNothingTheAppNeverUses() throws {
        let declared = try declaredCategories()
        let triggered = triggeredCategories(in: try sourceText(under: "LocalFileDiet"))

        for category in declared.keys {
            XCTAssertNotNil(
                triggered[category],
                "\(category) is declared but nothing in the app reaches an API in that category"
            )
        }
    }

    func testPrivacyManifestUsesReasonCodesApplePublishesForEachCategory() throws {
        for (category, reasons) in try declaredCategories() {
            let allowed = try XCTUnwrap(Self.allowedReasons[category], "unknown category \(category)")
            XCTAssertFalse(reasons.isEmpty, "\(category) declares no reason")
            for reason in reasons {
                XCTAssertTrue(allowed.contains(reason), "\(reason) is not a valid reason for \(category)")
            }
        }
    }

    /// Every file timestamp the app reads belongs to a file it put in its own
    /// container or in the app group container, which is exactly what C617.1
    /// covers. DDA9.1 would be wrong: nothing shows a file timestamp to the
    /// user, and the ZIP writer stamps timestamps into an archive the user can
    /// then send off the device.
    func testFileTimestampReasonMatchesWhatTheAppActuallyReads() throws {
        let declared = try declaredCategories()
        XCTAssertEqual(declared["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"])
    }

    /// The saved defaults are written and read by this app only - there is no
    /// shared suite and no managed configuration - so CA92.1 is the reason.
    func testUserDefaultsReasonMatchesHowDefaultsAreUsed() throws {
        let declared = try declaredCategories()
        XCTAssertEqual(declared["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])

        let sources = try sourceText(under: "LocalFileDiet")
        for (filename, text) in sources {
            XCTAssertFalse(
                text.contains("UserDefaults(suiteName:"),
                "\(filename) opens a shared defaults suite, which needs reason 1C8F.1 instead of CA92.1"
            )
        }
    }

    /// The share extension is its own bundle and ships without a privacy
    /// manifest, which is only correct while it stays clear of every
    /// required-reason API.
    func testShareExtensionUsesNoRequiredReasonAPI() throws {
        let triggered = triggeredCategories(in: try sourceText(under: "LocalFileDietShareExtension"))
        XCTAssertTrue(
            triggered.isEmpty,
            "the share extension now needs its own PrivacyInfo.xcprivacy: \(triggered)"
        )
    }

    func testAppDeclaresNoTrackingAndNoCollectedData() throws {
        let manifest = try plist(at: "LocalFileDiet/Resources/PrivacyInfo.xcprivacy")
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [String])?.count, 0)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Share extension activation rule

    private func activationRule() throws -> [String: Any] {
        let info = try plist(at: "LocalFileDietShareExtension/Info.plist")
        let extensionDictionary = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(
            extensionDictionary["NSExtensionAttributes"] as? [String: Any],
            "NSExtensionActivationRule must stay nested under NSExtensionAttributes (App Store error 90360)"
        )
        XCTAssertNil(
            extensionDictionary["NSExtensionActivationRule"],
            "NSExtensionActivationRule is at the top of NSExtension again, which is App Store error 90360"
        )
        return try XCTUnwrap(attributes["NSExtensionActivationRule"] as? [String: Any])
    }

    private static let maxCountKeys = [
        "NSExtensionActivationSupportsFileWithMaxCount",
        "NSExtensionActivationSupportsImageWithMaxCount",
        "NSExtensionActivationSupportsMovieWithMaxCount"
    ]

    func testActivationRuleIsNestedUnderExtensionAttributes() throws {
        XCTAssertFalse(try activationRule().isEmpty)
    }

    /// A max count of 1 makes iOS drop the extension out of the share sheet the
    /// moment the user picks a second file, which is how multi-file sharing
    /// disappeared without any error.
    func testActivationRuleAcceptsMoreThanOneOfEveryKind() throws {
        let rule = try activationRule()
        for key in Self.maxCountKeys {
            let count = try XCTUnwrap(rule[key] as? Int, "\(key) is missing from the activation rule")
            XCTAssertGreaterThan(count, 1, "\(key) still caps the share sheet at a single attachment")
        }
    }

    /// The advertised bound and the bound the extension enforces have to be the
    /// same number. Advertise more and attachments get silently dropped;
    /// advertise fewer and the extension hides itself for batches it could
    /// happily have taken.
    func testAdvertisedMaxCountMatchesTheExtensionsOwnCap() throws {
        let rule = try activationRule()
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("LocalFileDietShareExtension/ShareViewController.swift"),
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(pattern: #"maximumAttachments\s*=\s*(\d+)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let match = try XCTUnwrap(pattern.firstMatch(in: source, range: range), "no maximumAttachments in ShareViewController")
        let digits = try XCTUnwrap(Range(match.range(at: 1), in: source))
        let cap = try XCTUnwrap(Int(source[digits]))

        for key in Self.maxCountKeys {
            XCTAssertEqual(rule[key] as? Int, cap, "\(key) disagrees with ShareViewController.maximumAttachments")
        }
    }

    // MARK: - Share extension inbox hygiene

    /// `ShareViewController` belongs to the appex, which this target does not
    /// link, so the pruning rule itself cannot be called from here. These keep
    /// the calls that make it work from being dropped.
    private func shareExtensionSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("LocalFileDietShareExtension/ShareViewController.swift"),
            encoding: .utf8
        )
    }

    func testShareExtensionKeepsItsIncomingDirectoryTidy() throws {
        let source = try shareExtensionSource()
        XCTAssertTrue(source.contains("pruneUnreferencedFiles"), "nothing prunes stale files out of the app group Incoming directory")
        XCTAssertTrue(source.contains("isExcludedFromBackup"), "shared payloads are being backed up to iCloud")
        XCTAssertTrue(source.contains("FileProtectionType.completeUntilFirstUserAuthentication"), "shared payloads carry no file protection")
    }

    /// Pruning only unreferenced files still let a share the user backed out of
    /// sit in the app group container forever, because its own manifest kept
    /// referencing it. The age bound has to come from the manifest, not from
    /// the files: reading a file timestamp would put the appex into a
    /// required-reason category it has no privacy manifest to declare.
    func testShareExtensionBoundsAPendingShareByManifestAge() throws {
        let source = try shareExtensionSource()
        XCTAssertTrue(source.contains("pendingShareLifetime"), "a pending share is kept for good again")
        XCTAssertTrue(source.contains("isExpired"), "nothing decides when a pending share has gone stale")
        XCTAssertTrue(source.contains("createdAt"), "the expiry rule no longer reads the manifest's own timestamp")

        for needle in Self.categoryTriggers["NSPrivacyAccessedAPICategoryFileTimestamp"] ?? [] {
            XCTAssertFalse(
                source.contains(needle),
                "the expiry rule reached for \(needle); that needs a PrivacyInfo.xcprivacy in the appex"
            )
        }
    }

    /// The extension writes the manifest and the app reads it, across two
    /// bundles that share no types. `createdAt` is what the expiry rule turns
    /// on, so it has to survive the round trip.
    func testAppDecodesTheManifestShapeTheExtensionWrites() throws {
        let written = """
        {"items":[{"fileURL":"file:///private/var/mobile/Containers/Shared/AppGroup/X/Incoming/\
        1E1B0F0A-0000-0000-0000-00000000000A-IMG_0042.HEIC",\
        "originalFilename":"IMG_0042.HEIC","createdAt":765432100.0}]}
        """
        let manifest = try JSONDecoder().decode(SharedImportManifest.self, from: Data(written.utf8))
        let item = try XCTUnwrap(manifest.items.first)
        XCTAssertEqual(item.originalFilename, "IMG_0042.HEIC")
        XCTAssertEqual(item.fileURL.lastPathComponent, "1E1B0F0A-0000-0000-0000-00000000000A-IMG_0042.HEIC")
        XCTAssertEqual(item.createdAt.timeIntervalSinceReferenceDate, 765432100.0, accuracy: 0.001)
    }

    // MARK: - Settings privacy copy

    /// The old wording said file names and paths were not logged. `HistoryStore`
    /// writes both, and the home screen reads the names back out, so the app
    /// disproved its own privacy claim.
    func testHistoryStoresTheFilenameAndSandboxPathTheSettingsCopyDescribes() throws {
        let outputURL = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/X/Library/Caches/Outputs/Payslip-compressed-1a2b3c4d.pdf")
        let input = CompressionInput(
            id: UUID(),
            originalURL: outputURL,
            workingURL: outputURL,
            originalFilename: "Payslip.pdf",
            fileExtension: "pdf",
            detectedTypeIdentifier: "com.adobe.pdf",
            fileKind: .pdf,
            originalSizeBytes: 4_000_000,
            createdAt: Date()
        )
        let result = CompressionResult(
            outputURL: outputURL,
            outputFilename: outputURL.lastPathComponent,
            originalSizeBytes: 4_000_000,
            compressedSizeBytes: 900_000,
            targetReached: true,
            reductionPercent: 77.5,
            warnings: [],
            operationsApplied: [],
            durationSeconds: 1
        )
        let item = CompressionHistoryItem(input: input, result: result)
        let encoded = try JSONEncoder.pretty.encode([item])
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("Payslip-compressed-1a2b3c4d.pdf"), "history no longer stores the output filename")

        let decoded = try JSONDecoder.app.decode([CompressionHistoryItem].self, from: encoded)
        let row = try XCTUnwrap(decoded.first)
        XCTAssertEqual(row.outputFilename, "Payslip-compressed-1a2b3c4d.pdf")
        XCTAssertEqual(try XCTUnwrap(row.sandboxURL).path, outputURL.path, "history no longer stores the sandbox path")
        XCTAssertEqual(row.fileKind, .pdf)
        XCTAssertEqual(row.originalSizeBytes, 4_000_000)
        XCTAssertEqual(row.compressedSizeBytes, 900_000)
    }

    private func settingsSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("LocalFileDiet/Features/Settings/SettingsView.swift"),
            encoding: .utf8
        )
    }

    func testSettingsPrivacyCopyDoesNotDenyStoringNamesOrPaths() throws {
        let source = try settingsSource()
        // The claim the app itself falsifies.
        XCTAssertFalse(
            source.contains("File names and paths are not logged"),
            "Settings claims file names and paths are not stored while HistoryStore writes both"
        )
        XCTAssertTrue(
            source.contains("Recent history stays on this iPhone"),
            "the Privacy section no longer describes what recent history keeps"
        )
        XCTAssertTrue(
            source.contains("Output names are built from your original file names"),
            "the copy hides that keeping output names keeps the originals' names too"
        )
    }

    /// The reason that sentence has to be there: `Payslip March 2026.pdf` goes
    /// into history as `Payslip March 2026-compressed-<id>.pdf`. Saying only
    /// "the output file's name" would read as if the original name were gone.
    func testOutputNamesCarryTheOriginalFilenameIntoHistory() async throws {
        let original = "Payslip March 2026.pdf"

        XCTAssertTrue(
            OutputFilename.make(original: original, outputExtension: "pdf").hasPrefix("Payslip March 2026"),
            "the exported filename no longer starts from the original name"
        )

        // `makeOutputURL` only builds the name; nothing is written, so there is
        // nothing to tear down.
        let store = TemporaryFileStore()
        let outputURL = try await store.makeOutputURL(originalFilename: original, extension: "pdf")
        XCTAssertTrue(
            outputURL.lastPathComponent.contains("Payslip March 2026"),
            "history stores \(outputURL.lastPathComponent), which no longer contains the original name"
        )
    }

    /// Each remaining claim in the Privacy section, checked against the code.
    func testEveryRemainingPrivacyClaimHoldsUp() throws {
        let source = try settingsSource()

        // "No uploads": there is no networking anywhere in the app target.
        for (filename, text) in try sourceText(under: "LocalFileDiet") {
            for needle in ["URLSession", "NWConnection", "CFURLRequest", "NSURLConnection"] {
                XCTAssertFalse(text.contains(needle), "\(filename) uses \(needle); Settings still claims No uploads")
            }
        }

        // "Files stay on your iPhone" on its own was more than the app delivers,
        // because every result screen offers a share sheet.
        XCTAssertFalse(
            source.contains(#"Label("Files stay on your iPhone", systemImage"#),
            "the unqualified claim is back, and the app can still share files off the device"
        )
        XCTAssertTrue(source.contains("Files stay on your iPhone unless you share them"))

        // "Clear temporary files below deletes the files it points at": history
        // rows point into Caches/Outputs, which is one of the directories
        // clearAll removes.
        let storeSource = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("LocalFileDiet/Core/FileImport/TemporaryFileStore.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            storeSource.contains("func clearAll") && storeSource.contains("outputsDirectory()"),
            "Clear temporary files no longer removes the outputs directory the history rows point at"
        )
    }

    /// The number in the copy has to be the number the store actually keeps.
    @MainActor
    func testSettingsCopyKeepsTheSameHistoryLimitTheStoreEnforces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-limit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(fileManager: RedirectedFileManager(applicationSupport: directory))
        for index in 1...30 {
            let url = directory.appendingPathComponent("file-\(index).pdf")
            let input = CompressionInput(
                id: UUID(),
                originalURL: url,
                workingURL: url,
                originalFilename: "file-\(index).pdf",
                fileExtension: "pdf",
                detectedTypeIdentifier: "com.adobe.pdf",
                fileKind: .pdf,
                originalSizeBytes: 100,
                createdAt: Date()
            )
            let result = CompressionResult(
                outputURL: url,
                outputFilename: url.lastPathComponent,
                originalSizeBytes: 100,
                compressedSizeBytes: 50,
                targetReached: true,
                reductionPercent: 50,
                warnings: [],
                operationsApplied: [],
                durationSeconds: 1
            )
            store.add(input: input, result: result)
        }
        XCTAssertEqual(store.items.count, 25, "Settings says the last 25 entries are kept")

        store.clear()
        XCTAssertTrue(store.items.isEmpty, "Settings says Clear removes all of it")
        let saved = try Data(contentsOf: directory
            .appendingPathComponent("LocalFileDiet", isDirectory: true)
            .appendingPathComponent("history.json"))
        let text = try XCTUnwrap(String(data: saved, encoding: .utf8))
        XCTAssertFalse(text.contains("file-30.pdf"), "Clear left file names on disk")
    }
}

/// Points `HistoryStore` at a scratch directory instead of the real
/// Application Support folder.
private final class RedirectedFileManager: FileManager {
    private let applicationSupport: URL

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        return [applicationSupport]
    }
}
