import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum FileKind: String, Codable, CaseIterable, Sendable, Hashable {
    case image
    case pdf
    case video
    case archive
    case unsupported

    var displayName: String {
        switch self {
        case .image: "Image"
        case .pdf: "PDF"
        case .video: "Video"
        case .archive: "Archive"
        case .unsupported: "Unsupported"
        }
    }
}

struct CompressionInput: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let originalURL: URL
    let workingURL: URL
    let originalFilename: String
    let fileExtension: String?
    let detectedTypeIdentifier: String?
    let fileKind: FileKind
    let originalSizeBytes: Int64
    let createdAt: Date
}

struct CompressionSettings: Codable, Equatable, Sendable, Hashable {
    var targetSizeBytes: Int64?
    var qualityMode: QualityMode
    var outputFormat: OutputFormat
    var stripMetadata: Bool
    var preserveTransparency: Bool
    var preferHEICWhenAvailable: Bool
    var allowResolutionDownscale: Bool
    var maxDimension: Int?
    var videoResolutionPreset: VideoResolutionPreset?

    static let balanced = CompressionSettings(
        targetSizeBytes: TargetSizePreset.forms.bytes,
        qualityMode: .balanced,
        outputFormat: .automatic,
        stripMetadata: true,
        preserveTransparency: true,
        preferHEICWhenAvailable: false,
        allowResolutionDownscale: true,
        maxDimension: nil,
        videoResolutionPreset: .auto
    )

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> CompressionSettings {
        var settings = CompressionSettings.balanced
        if let presetRaw = defaults.string(forKey: AppDefaults.defaultTargetPresetKey),
           let preset = TargetSizePreset(rawValue: presetRaw) {
            settings.targetSizeBytes = preset.bytes
        }
        if let qualityRaw = defaults.string(forKey: AppDefaults.defaultQualityModeKey),
           let mode = QualityMode(rawValue: qualityRaw) {
            settings.qualityMode = mode
        }
        if defaults.object(forKey: AppDefaults.stripMetadataKey) != nil {
            settings.stripMetadata = defaults.bool(forKey: AppDefaults.stripMetadataKey)
        }
        settings.preferHEICWhenAvailable = defaults.bool(forKey: AppDefaults.preferHEICKey)
        return settings
    }
}

enum QualityMode: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case bestQuality
    case balanced
    case smallestFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bestQuality: "Best"
        case .balanced: "Balanced"
        case .smallestFile: "Smallest"
        }
    }

    var fullTitle: String {
        switch self {
        case .bestQuality: "Best quality"
        case .balanced: "Balanced"
        case .smallestFile: "Smallest file"
        }
    }

    var compressionQualityRange: ClosedRange<Double> {
        switch self {
        case .bestQuality: 0.72...0.95
        case .balanced: 0.55...0.90
        case .smallestFile: 0.35...0.82
        }
    }

    /// Bounds for the PDF engine's measured DPI search.
    ///
    /// This replaced a fixed ladder of four DPI values per mode, which the old
    /// engine walked exhaustively. The search now starts from a measured page
    /// and only needs to know how far it is allowed to move: the lower bound is
    /// where a scan stops being readable, the upper bound is where more pixels
    /// stop being worth their bytes.
    var pdfDPIRange: ClosedRange<CGFloat> {
        switch self {
        case .bestQuality: 150...220
        case .balanced: 110...180
        case .smallestFile: 72...130
        }
    }

    var imageLongEdgeSequence: [Int] {
        switch self {
        case .bestQuality: [4096, 3072, 2560, 2048, 1600]
        case .balanced: [3072, 2560, 2048, 1600, 1280, 1024]
        case .smallestFile: [2560, 2048, 1600, 1280, 1024, 768]
        }
    }
}

enum OutputFormat: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case automatic
    case jpeg
    case heic
    case png
    case pdf
    case mp4
    case mov
    case zip
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: "PNG"
        case .pdf: "PDF"
        case .mp4: "MP4"
        case .mov: "MOV"
        case .zip: "ZIP"
        case .original: "Original"
        }
    }

    var pathExtension: String {
        switch self {
        case .automatic, .original: ""
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png: "png"
        case .pdf: "pdf"
        case .mp4: "mp4"
        case .mov: "mov"
        case .zip: "zip"
        }
    }
}

enum VideoResolutionPreset: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case auto
    case keepResolution
    case p1080
    case p720
    case p540
    case p480

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .keepResolution: "Keep"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p540: "540p"
        case .p480: "480p"
        }
    }
}

enum PredictedQuality: String, Codable, CaseIterable, Sendable, Hashable {
    case excellent
    case good
    case acceptable
    case low

    var title: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .acceptable: "Acceptable"
        case .low: "Low"
        }
    }
}

struct CompressionWarning: Codable, Identifiable, Sendable, Hashable {
    enum Severity: String, Codable, Sendable, Hashable {
        case info
        case caution
        case blocking
    }

    let id: String
    let severity: Severity
    let title: String
    let message: String

    static let alreadyOptimized = CompressionWarning(
        id: "alreadyOptimized",
        severity: .info,
        title: "Already optimized",
        message: "This file may not get much smaller without visible quality loss."
    )

    static let targetMayBeUnrealistic = CompressionWarning(
        id: "targetMayBeUnrealistic",
        severity: .caution,
        title: "Target may be too small",
        message: "We will try the target, but quality may need to drop noticeably."
    )

    static let rasterizesPDF = CompressionWarning(
        id: "rasterizesPDF",
        severity: .caution,
        title: "Photo pages will be rebuilt",
        message: "Pages that are mostly photo or scan get rebuilt as images. Text pages keep their selectable text, but links and annotations on rebuilt pages may be lost."
    )

    /// The same warning, told in terms of how much of the document it touches.
    /// Only the photo pages are rebuilt, so "12 of 200 pages" is a very
    /// different promise from "your PDF will become pictures".
    static func pdfPagesRebuilt(imageDominantPages: Int, of pageCount: Int) -> CompressionWarning {
        CompressionWarning(
            id: rasterizesPDF.id,
            severity: .caution,
            title: rasterizesPDF.title,
            message: "\(imageDominantPages) of \(pageCount) page\(pageCount == 1 ? "" : "s") are mostly photo or scan and will be rebuilt as images. The other pages keep their selectable text, but links and annotations on rebuilt pages may be lost."
        )
    }

    /// No page can be rebuilt without costing the user their text, so nothing is.
    ///
    /// `imagesUnderText` covers the scanned-and-then-OCRed document: it does hold
    /// big pictures, but every one of them sits under searchable text, and saying
    /// "no photos inside" would be a lie.
    static func pdfTextOnly(smallestFileRequested: Bool, imagesUnderText: Bool = false) -> CompressionWarning {
        let message: String
        if imagesUnderText {
            message = "Every page in this PDF has selectable text on it, including the pages with pictures. The only way to shrink those pages is to rebuild them as images, which would throw the text away, so your original file was kept unchanged."
        } else if smallestFileRequested {
            message = "This PDF is text and drawings, with no photos or scans inside. Smallest file would have to turn every page into a picture, which throws away the selectable text and often makes the file bigger, so your original was kept unchanged."
        } else {
            message = "This PDF is text and drawings, with no photos or scans inside. There is nothing to re-compress without destroying the text, so your original file was kept unchanged."
        }
        return CompressionWarning(
            id: "pdfTextOnly",
            severity: .info,
            title: "Nothing to shrink here",
            message: message
        )
    }

    static let pdfAnnotations = CompressionWarning(
        id: "pdfAnnotations",
        severity: .caution,
        title: "PDF has annotations",
        message: "Interactive annotations or forms may not survive a page rebuild."
    )

    static let heicCompatibility = CompressionWarning(
        id: "heicCompatibility",
        severity: .caution,
        title: "Modern format",
        message: "HEIC can be smaller, but older websites may not accept it."
    )

    static let transparencyFlattened = CompressionWarning(
        id: "transparencyFlattened",
        severity: .caution,
        title: "Transparency removed",
        message: "This image had transparent areas. The chosen format cannot store them, so they were filled with white."
    )

    static let keptOriginal = CompressionWarning(
        id: "keptOriginal",
        severity: .info,
        title: "Original kept",
        message: "This file was already as small as it can get with these settings, so your original file was kept unchanged."
    )

    static let videoPrecision = CompressionWarning(
        id: "videoPrecision",
        severity: .info,
        title: "Aiming at your target",
        message: "The video is re-encoded at a bitrate worked out from your target size, so it should land just under it. Very short clips and very small targets can still finish a little off."
    )

    /// The reader/writer pipeline could not run for this file, so the engine
    /// used a built-in Apple preset instead. Presets carry fixed bitrates, so
    /// the size is whatever the preset produces — this is the one case where
    /// the app cannot aim.
    static let videoPresetFallback = CompressionWarning(
        id: "videoPresetFallback",
        severity: .caution,
        title: "Used a built-in preset",
        message: "This video could not be re-encoded at a chosen bitrate, so a built-in Apple preset was used instead. The file is still smaller, but its size is approximate rather than aimed at your target."
    )

    /// Genuinely useful before pressing go: "will export at 1280x720, H.264".
    static func videoOutputPlan(width: Int, height: Int, codec: String) -> CompressionWarning {
        CompressionWarning(
            id: "videoOutputPlan",
            severity: .info,
            title: "Will export at \(width)x\(height)",
            message: "This video will be re-encoded at \(width)x\(height) using \(codec)."
        )
    }

    static let videoModernCodec = CompressionWarning(
        id: "videoModernCodec",
        severity: .caution,
        title: "Modern video format",
        message: "HEVC needs about half the bitrate of H.264 for the same picture, but some older computers, websites and phones cannot play it. Turn off \"Prefer smaller modern format\" if the file has to work everywhere."
    )
}

struct CompressionOperation: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let title: String

    static let stripMetadata = CompressionOperation(id: "stripMetadata", title: "Remove metadata")
    static let downsample = CompressionOperation(id: "downsample", title: "Downsample pixels")
    static let reencode = CompressionOperation(id: "reencode", title: "Re-encode")
    static let pdfRasterRebuild = CompressionOperation(id: "pdfRasterRebuild", title: "Rebuild scanned pages")
    static let videoExport = CompressionOperation(id: "videoExport", title: "Re-encode video at a target bitrate")
    static let zip = CompressionOperation(id: "zip", title: "Create ZIP")
    static let verifyOutput = CompressionOperation(id: "verifyOutput", title: "Verify output")
}

struct CompressionEstimate: Codable, Sendable, Hashable {
    let estimatedSizeBytes: Int64?
    let estimatedReductionPercent: Double?
    let predictedQuality: PredictedQuality
    let warnings: [CompressionWarning]
    let plannedOperations: [CompressionOperation]
}

struct CompressionResult: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let outputURL: URL
    let outputFilename: String
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let targetReached: Bool
    let reductionPercent: Double
    let warnings: [CompressionWarning]
    let operationsApplied: [CompressionOperation]
    let durationSeconds: Double

    init(
        id: UUID = UUID(),
        outputURL: URL,
        outputFilename: String,
        originalSizeBytes: Int64,
        compressedSizeBytes: Int64,
        targetReached: Bool,
        reductionPercent: Double,
        warnings: [CompressionWarning],
        operationsApplied: [CompressionOperation],
        durationSeconds: Double
    ) {
        self.id = id
        self.outputURL = outputURL
        self.outputFilename = outputFilename
        self.originalSizeBytes = originalSizeBytes
        self.compressedSizeBytes = compressedSizeBytes
        self.targetReached = targetReached
        self.reductionPercent = reductionPercent
        self.warnings = warnings
        self.operationsApplied = operationsApplied
        self.durationSeconds = durationSeconds
    }
}

struct CompressionProgress: Sendable, Hashable {
    let phase: CompressionPhase
    let fractionCompleted: Double?
    let message: String

    static let preparing = CompressionProgress(phase: .preparing, fractionCompleted: 0, message: "Preparing file")
}

enum CompressionPhase: String, Sendable, Hashable {
    case preparing
    case analyzing
    case downsampling
    case encoding
    case optimizing
    case writing
    case verifying
    case completed
}

enum TargetSizePreset: String, CaseIterable, Identifiable, Codable, Sendable, Hashable {
    case email25
    case common20
    case forms
    case strict5
    case veryStrict2
    case pec10
    case quickShare16

    var id: String { rawValue }

    var title: String {
        switch self {
        case .email25: "Under 25 MB"
        case .common20: "Under 20 MB"
        case .forms: "Under 10 MB"
        case .strict5: "Under 5 MB"
        case .veryStrict2: "Under 2 MB"
        case .pec10: "PEC / public portal"
        case .quickShare16: "Quick share"
        }
    }

    var subtitle: String {
        switch self {
        case .email25: "Email-friendly"
        case .common20: "Common upload limit"
        case .forms: "Forms and portals"
        case .strict5: "Strict forms"
        case .veryStrict2: "Very strict upload"
        case .pec10: "10 MB preset"
        case .quickShare16: "16 MB preset"
        }
    }

    var bytes: Int64 {
        switch self {
        case .email25: 25 * 1_000_000
        case .common20: 20 * 1_000_000
        case .forms, .pec10: 10 * 1_000_000
        case .strict5: 5 * 1_000_000
        case .veryStrict2: 2 * 1_000_000
        case .quickShare16: 16 * 1_000_000
        }
    }
}

enum AppDefaults {
    static let defaultTargetPresetKey = "defaultTargetPreset"
    static let defaultQualityModeKey = "defaultQualityMode"
    static let stripMetadataKey = "stripMetadataDefault"
    static let preferHEICKey = "preferHEICWhenAvailable"
}
