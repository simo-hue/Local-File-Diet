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

    var pdfDPISequence: [CGFloat] {
        switch self {
        case .bestQuality: [220, 200, 180, 160]
        case .balanced: [180, 160, 150, 130]
        case .smallestFile: [130, 115, 100, 90]
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
        title: "PDF will be rebuilt as images",
        message: "This can reduce scanned PDFs a lot, but selectable text, links, forms, and annotations may be lost."
    )

    static let vectorPDFProtected = CompressionWarning(
        id: "vectorPDF",
        severity: .info,
        title: "Mostly text PDF",
        message: "This looks like a text or vector PDF, so aggressive scan compression is avoided by default."
    )

    static let heicCompatibility = CompressionWarning(
        id: "heicCompatibility",
        severity: .caution,
        title: "Modern format",
        message: "HEIC can be smaller, but older websites may not accept it."
    )

    static let videoPrecision = CompressionWarning(
        id: "videoPrecision",
        severity: .info,
        title: "Estimated video target",
        message: "Video export uses local Apple presets, so the final size can be close to the target but not exact."
    )
}

struct CompressionOperation: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let title: String

    static let stripMetadata = CompressionOperation(id: "stripMetadata", title: "Remove metadata")
    static let downsample = CompressionOperation(id: "downsample", title: "Downsample pixels")
    static let reencode = CompressionOperation(id: "reencode", title: "Re-encode")
    static let pdfRasterRebuild = CompressionOperation(id: "pdfRasterRebuild", title: "Rebuild scanned pages")
    static let videoExport = CompressionOperation(id: "videoExport", title: "Export with Apple video preset")
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
