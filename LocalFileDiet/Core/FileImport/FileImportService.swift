import Foundation
import UniformTypeIdentifiers

protocol FileImportServicing {
    func importFile(from url: URL) async throws -> CompressionInput
    func importPhotoFile(from url: URL, suggestedName: String?) async throws -> CompressionInput
    func importSharedFileIfAvailable() async throws -> CompressionInput?
}

struct FileImportService: FileImportServicing {
    private let store: TemporaryFileStoring
    private let detector: FileTypeDetector
    private let fileManager: FileManager
    private let appGroupIdentifier: String

    init(
        store: TemporaryFileStoring,
        detector: FileTypeDetector = FileTypeDetector(),
        fileManager: FileManager = .default,
        appGroupIdentifier: String = AppGroup.identifier
    ) {
        self.store = store
        self.detector = detector
        self.fileManager = fileManager
        self.appGroupIdentifier = appGroupIdentifier
    }

    func importFile(from url: URL) async throws -> CompressionInput {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await createInput(from: url, preferredFilename: nil)
    }

    func importPhotoFile(from url: URL, suggestedName: String?) async throws -> CompressionInput {
        try await createInput(from: url, preferredFilename: suggestedName)
    }

    func importSharedFileIfAvailable() async throws -> CompressionInput? {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }
        let manifestURL = container.appendingPathComponent("Incoming/share-manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SharedImportManifest.self, from: data)
        guard let item = manifest.items.first else { return nil }
        let input = try await createInput(from: item.fileURL, preferredFilename: item.originalFilename)
        try? fileManager.removeItem(at: item.fileURL)
        try? fileManager.removeItem(at: manifestURL)
        return input
    }

    private func createInput(from sourceURL: URL, preferredFilename: String?) async throws -> CompressionInput {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw AppError.fileUnavailable
        }
        let workingURL = try await store.copyIntoWorkingDirectory(from: sourceURL, preferredFilename: preferredFilename)
        let detection = detector.detect(url: workingURL)
        let attributes = try fileManager.attributesOfItem(atPath: workingURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return CompressionInput(
            id: UUID(),
            originalURL: sourceURL,
            workingURL: workingURL,
            originalFilename: preferredFilename ?? sourceURL.lastPathComponent,
            fileExtension: sourceURL.pathExtension.isEmpty ? nil : sourceURL.pathExtension.lowercased(),
            detectedTypeIdentifier: detection.type?.identifier,
            fileKind: detection.kind,
            originalSizeBytes: size,
            createdAt: Date()
        )
    }
}

enum AppGroup {
    static let identifier = "group.com.simohue.localfilediet"
    static let urlScheme = "localfilediet"
}

struct SharedImportManifest: Codable {
    struct Item: Codable {
        let fileURL: URL
        let originalFilename: String
        let createdAt: Date
    }

    let items: [Item]
}
