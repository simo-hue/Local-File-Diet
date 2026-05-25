import Foundation

struct ArchiveCompressionEngine: CompressionEngine {
    private let store: TemporaryFileStoring
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        CompressionEstimate(
            estimatedSizeBytes: input.originalSizeBytes,
            estimatedReductionPercent: 0,
            predictedQuality: .excellent,
            warnings: [
                CompressionWarning(
                    id: "zipAlreadyCompressed",
                    severity: .info,
                    title: "ZIP files are usually already compressed",
                    message: "Creating a new ZIP is useful for packaging, but it may not reduce size."
                )
            ],
            plannedOperations: [.zip, .verifyOutput]
        )
    }

    func compress(
        input: CompressionInput,
        settings: CompressionSettings,
        progress: @escaping @Sendable (CompressionProgress) -> Void
    ) async throws -> CompressionResult {
        let start = Date()
        progress(.preparing)
        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: "zip")
        progress(CompressionProgress(phase: .writing, fractionCompleted: 0.5, message: "Creating ZIP"))
        try SimpleZIPWriter.write(files: [input.workingURL], to: outputURL)
        let size = fileManager.fileSize(at: outputURL)
        guard size > 0 else {
            throw AppError.exportFailed
        }
        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "ZIP ready"))
        return CompressionResult(
            outputURL: outputURL,
            outputFilename: outputURL.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: size,
            targetReached: CompressionMath.targetReached(size: size, target: settings.targetSizeBytes),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: size),
            warnings: [
                CompressionWarning(
                    id: "zipPackagingOnly",
                    severity: .info,
                    title: "Packaged locally",
                    message: "The file was packaged as ZIP locally. Already compressed files may not become smaller."
                )
            ],
            operationsApplied: [.zip, .verifyOutput],
            durationSeconds: Date().timeIntervalSince(start)
        )
    }
}

enum SimpleZIPWriter {
    static func write(files: [URL], to outputURL: URL) throws {
        var archive = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for fileURL in files {
            try Task.checkCancellation()
            let fileData = try Data(contentsOf: fileURL)
            let filename = fileURL.lastPathComponent.data(using: .utf8) ?? Data("file".utf8)
            let crc = CRC32.checksum(fileData)
            let compressedSize = UInt32(fileData.count)
            let uncompressedSize = UInt32(fileData.count)

            var local = Data()
            local.appendUInt32LE(0x04034b50)
            local.appendUInt16LE(20)
            local.appendUInt16LE(0)
            local.appendUInt16LE(0)
            local.appendUInt16LE(0)
            local.appendUInt16LE(0)
            local.appendUInt32LE(crc)
            local.appendUInt32LE(compressedSize)
            local.appendUInt32LE(uncompressedSize)
            local.appendUInt16LE(UInt16(filename.count))
            local.appendUInt16LE(0)
            local.append(filename)
            archive.append(local)
            archive.append(fileData)

            var central = Data()
            central.appendUInt32LE(0x02014b50)
            central.appendUInt16LE(20)
            central.appendUInt16LE(20)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt32LE(crc)
            central.appendUInt32LE(compressedSize)
            central.appendUInt32LE(uncompressedSize)
            central.appendUInt16LE(UInt16(filename.count))
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt16LE(0)
            central.appendUInt32LE(0)
            central.appendUInt32LE(offset)
            central.append(filename)
            centralDirectory.append(central)
            offset = UInt32(archive.count)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x06054b50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(files.count))
        archive.appendUInt16LE(UInt16(files.count))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(centralDirectoryOffset)
        archive.appendUInt16LE(0)
        try archive.write(to: outputURL, options: [.atomic])
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
