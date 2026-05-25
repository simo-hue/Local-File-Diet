import Foundation
import Observation

struct CompressionHistoryItem: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    let outputFilename: String
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let reductionPercent: Double
    let fileKind: FileKind
    let createdAt: Date
    let sandboxURL: URL?

    init(input: CompressionInput, result: CompressionResult) {
        self.id = result.id
        self.outputFilename = result.outputFilename
        self.originalSizeBytes = result.originalSizeBytes
        self.compressedSizeBytes = result.compressedSizeBytes
        self.reductionPercent = result.reductionPercent
        self.fileKind = input.fileKind
        self.createdAt = Date()
        self.sandboxURL = result.outputURL
    }
}

@Observable
final class HistoryStore: @unchecked Sendable {
    private(set) var items: [CompressionHistoryItem] = []
    private let fileURL: URL
    private let maxItems = 25

    init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = applicationSupport.appendingPathComponent("LocalFileDiet", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("history.json")
        load()
    }

    @MainActor
    func add(input: CompressionInput, result: CompressionResult) {
        let item = CompressionHistoryItem(input: input, result: result)
        items.insert(item, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        save()
    }

    @MainActor
    func delete(_ item: CompressionHistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    @MainActor
    func clear() {
        items = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        items = (try? JSONDecoder().decode([CompressionHistoryItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder.pretty.encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var app: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
