import Compression
import Foundation

struct ArchiveCompressionEngine: CompressionEngine {
    private let store: TemporaryFileStoring
    private let fileManager: FileManager

    init(store: TemporaryFileStoring, fileManager: FileManager = .default) {
        self.store = store
        self.fileManager = fileManager
    }

    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate {
        if input.fileKind == .archive {
            // The contents may have been stored or weakly deflated, so a re-pack
            // can genuinely help. How much is not knowable without reading it.
            return CompressionEstimate(
                estimatedSizeBytes: nil,
                estimatedReductionPercent: nil,
                predictedQuality: .excellent,
                warnings: [.zipRepack],
                plannedOperations: [.zip, .verifyOutput]
            )
        }

        if Self.isAlreadyCompressed(input) {
            return CompressionEstimate(
                estimatedSizeBytes: input.originalSizeBytes,
                estimatedReductionPercent: 0,
                predictedQuality: .excellent,
                warnings: [.zipAlreadyCompressed],
                plannedOperations: [.zip, .verifyOutput]
            )
        }

        return CompressionEstimate(
            estimatedSizeBytes: nil,
            estimatedReductionPercent: nil,
            predictedQuality: .excellent,
            warnings: [],
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
        try Task.checkCancellation()

        let outputURL = try await store.makeOutputURL(originalFilename: input.originalFilename, extension: "zip")
        var warnings: [CompressionWarning] = []
        var repacked = false

        if input.fileKind == .archive {
            do {
                progress(CompressionProgress(phase: .analyzing, fractionCompleted: 0.05, message: "Reading archive"))
                let entries = try SimpleZIPReader.read(url: input.workingURL)
                guard !entries.isEmpty else {
                    throw ZIPError.unsupported("the archive contains no files to re-pack")
                }
                try Task.checkCancellation()
                try SimpleZIPWriter.write(entries: entries, to: outputURL) { fraction in
                    progress(CompressionProgress(
                        phase: .encoding,
                        fractionCompleted: 0.1 + fraction * 0.8,
                        message: "Re-packing archive contents"
                    ))
                }
                warnings.append(.zipRepacked)
                repacked = true
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Unsupported or damaged archive: fall back to wrapping it as-is
                // rather than failing the whole operation.
                warnings.append(.zipCouldNotRepack)
            }
        }

        if !repacked {
            try Task.checkCancellation()
            try SimpleZIPWriter.write(files: [input.workingURL], to: outputURL) { fraction in
                progress(CompressionProgress(
                    phase: .encoding,
                    fractionCompleted: 0.1 + fraction * 0.8,
                    message: "Creating ZIP"
                ))
            }
            if Self.isAlreadyCompressed(input) {
                warnings.append(.zipAlreadyCompressed)
            }
        }

        try Task.checkCancellation()
        progress(CompressionProgress(phase: .verifying, fractionCompleted: 0.94, message: "Checking the result"))
        let resolved = try await OutputGuard.resolve(
            candidateURL: outputURL,
            input: input,
            store: store,
            fileManager: fileManager
        )
        let finalSize = fileManager.fileSize(at: resolved.url)
        guard finalSize > 0 else {
            throw AppError.exportFailed
        }
        if resolved.keptOriginal {
            warnings = OutputGuard.warningsAfterKeepingOriginal(
                warnings,
                finalSize: finalSize,
                target: settings.targetSizeBytes
            )
        }

        progress(CompressionProgress(phase: .completed, fractionCompleted: 1, message: "ZIP ready"))
        return CompressionResult(
            outputURL: resolved.url,
            outputFilename: resolved.url.lastPathComponent,
            originalSizeBytes: input.originalSizeBytes,
            compressedSizeBytes: finalSize,
            targetReached: CompressionMath.targetReached(size: finalSize, target: settings.targetSizeBytes),
            reductionPercent: CompressionMath.reductionPercent(original: input.originalSizeBytes, compressed: finalSize),
            warnings: warnings,
            operationsApplied: [.zip, .verifyOutput],
            durationSeconds: Date().timeIntervalSince(start)
        )
    }

    /// True when the payload is a format that already carries its own
    /// compression, so wrapping it in a ZIP will not shrink it.
    static func isAlreadyCompressed(_ input: CompressionInput) -> Bool {
        let compressedExtensions: Set<String> = [
            "jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "avif", "tif", "tiff",
            "mp4", "mov", "m4v", "hevc", "avi", "mkv", "webm",
            "mp3", "aac", "m4a", "ogg", "opus", "flac",
            "zip", "7z", "rar", "gz", "bz2", "xz", "tgz",
            "docx", "xlsx", "pptx", "epub", "ipa", "apk"
        ]
        let declared = (input.fileExtension ?? "").lowercased()
        let derived = URL(fileURLWithPath: input.originalFilename).pathExtension.lowercased()
        if compressedExtensions.contains(declared) || compressedExtensions.contains(derived) {
            return true
        }
        switch input.fileKind {
        case .image, .video, .archive:
            return true
        case .pdf, .unsupported:
            return false
        }
    }
}

extension CompressionWarning {
    static let zipRepack = CompressionWarning(
        id: "zipRepack",
        severity: .info,
        title: "Re-packing the archive",
        message: "This ZIP may re-pack the contents with stronger compression. If that does not make it smaller, your original file is kept."
    )

    static let zipRepacked = CompressionWarning(
        id: "zipRepacked",
        severity: .info,
        title: "Contents re-packed",
        message: "The archive contents were unpacked and re-packed locally with stronger compression."
    )

    static let zipCouldNotRepack = CompressionWarning(
        id: "zipCouldNotRepack",
        severity: .info,
        title: "Contents left untouched",
        message: "This archive uses features we do not read (for example encryption or ZIP64), so it was wrapped as-is instead of re-packed."
    )

    static let zipAlreadyCompressed = CompressionWarning(
        id: "zipAlreadyCompressed",
        severity: .info,
        title: "This file is already compressed",
        message: "Creating a ZIP is useful for packaging, but this format is already compressed so it may not get smaller."
    )
}

/// One file inside a ZIP archive.
struct ZIPEntrySource: Sendable, Hashable {
    let name: String
    let data: Data
}

enum ZIPError: Error {
    case unsupported(String)
    case malformed(String)
}

enum ZIPFormat {
    static let localHeaderSignature: UInt32 = 0x04034b50
    static let centralHeaderSignature: UInt32 = 0x02014b50
    static let endOfCentralDirectorySignature: UInt32 = 0x06054b50
    static let versionNeeded: UInt16 = 20
    static let versionMadeBy: UInt16 = 20
    /// Bit 11 marks the filename as UTF-8, which is what we always write.
    static let utf8NameFlag: UInt16 = 0x0800
    static let methodStore: UInt16 = 0
    static let methodDeflate: UInt16 = 8
    static let localHeaderLength = 30
    static let centralHeaderLength = 46
    static let endOfCentralDirectoryLength = 22

    /// Normalises an entry name to a safe relative POSIX path:
    /// forward slashes only, no leading "/", no "." or ".." components.
    static func normalizedEntryName(_ raw: String) -> String {
        let unified = raw.replacingOccurrences(of: "\\", with: "/")
        let components = unified
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != ".." && $0 != "." }
        let joined = components.joined(separator: "/")
        return joined.isEmpty ? "file" : joined
    }

    /// MS-DOS date/time as used by the ZIP headers. The DOS epoch is 1980 and
    /// seconds are stored in two-second units.
    static func dosDateTime(from date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = parts.year ?? 0
        guard year >= 1980, year <= 2107 else {
            return (0, UInt16((1 << 5) | 1))
        }
        let day = min(max(parts.day ?? 1, 1), 31)
        let month = min(max(parts.month ?? 1, 1), 12)
        let hour = min(max(parts.hour ?? 0, 0), 23)
        let minute = min(max(parts.minute ?? 0, 0), 59)
        let second = min(max(parts.second ?? 0, 0), 59)
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        return (dosTime, dosDate)
    }
}

enum SimpleZIPWriter {
    /// Writes each file as its own entry, named after its last path component.
    static func write(files: [URL], to outputURL: URL, progress: (Double) -> Void = { _ in }) throws {
        var entries: [ZIPEntrySource] = []
        var dates: [Date] = []
        entries.reserveCapacity(files.count)
        dates.reserveCapacity(files.count)
        for fileURL in files {
            try Task.checkCancellation()
            entries.append(ZIPEntrySource(name: fileURL.lastPathComponent, data: try Data(contentsOf: fileURL)))
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            dates.append((attributes?[.modificationDate] as? Date) ?? Date())
        }
        try write(entries: entries, modificationDates: dates, to: outputURL, progress: progress)
    }

    /// Writes pre-loaded entries, preserving their (normalised) relative paths.
    static func write(entries: [ZIPEntrySource], to outputURL: URL, progress: (Double) -> Void = { _ in }) throws {
        try write(entries: entries, modificationDates: [], to: outputURL, progress: progress)
    }

    private static func write(
        entries: [ZIPEntrySource],
        modificationDates: [Date],
        to outputURL: URL,
        progress: (Double) -> Void
    ) throws {
        var archive = Data()
        var centralDirectory = Data()
        var writtenEntries = 0
        let fallbackDate = Date()

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            progress(entries.isEmpty ? 1 : Double(index) / Double(entries.count))

            // Directory markers carry no payload; the tree is implied by the entry names.
            if entry.name.hasSuffix("/") { continue }
            let name = ZIPFormat.normalizedEntryName(entry.name)
            let nameData = Data(name.utf8)
            let raw = entry.data

            // ZIP64 is not implemented: every size and offset field below is 32-bit,
            // so anything at or beyond UInt32.max would silently wrap and produce a
            // corrupt archive. Refuse instead.
            guard nameData.count <= Int(UInt16.max),
                  raw.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw AppError.exportFailed
            }

            let crc = CRC32.checksum(raw)
            var method = ZIPFormat.methodStore
            var payload = raw
            if let deflated = deflate(raw), deflated.count < raw.count {
                method = ZIPFormat.methodDeflate
                payload = deflated
            }
            guard payload.count <= Int(UInt32.max) else { throw AppError.exportFailed }

            let localHeaderOffset = UInt32(archive.count)
            let date = modificationDates.indices.contains(index) ? modificationDates[index] : fallbackDate
            let stamp = ZIPFormat.dosDateTime(from: date)
            let compressedSize = UInt32(payload.count)
            let uncompressedSize = UInt32(raw.count)

            var local = Data()
            local.appendUInt32LE(ZIPFormat.localHeaderSignature)
            local.appendUInt16LE(ZIPFormat.versionNeeded)
            local.appendUInt16LE(ZIPFormat.utf8NameFlag)
            local.appendUInt16LE(method)
            local.appendUInt16LE(stamp.time)
            local.appendUInt16LE(stamp.date)
            local.appendUInt32LE(crc)
            local.appendUInt32LE(compressedSize)
            local.appendUInt32LE(uncompressedSize)
            local.appendUInt16LE(UInt16(nameData.count))
            local.appendUInt16LE(0)
            local.append(nameData)
            archive.append(local)
            archive.append(payload)

            var central = Data()
            central.appendUInt32LE(ZIPFormat.centralHeaderSignature)
            central.appendUInt16LE(ZIPFormat.versionMadeBy)
            central.appendUInt16LE(ZIPFormat.versionNeeded)
            central.appendUInt16LE(ZIPFormat.utf8NameFlag)
            central.appendUInt16LE(method)
            central.appendUInt16LE(stamp.time)
            central.appendUInt16LE(stamp.date)
            central.appendUInt32LE(crc)
            central.appendUInt32LE(compressedSize)
            central.appendUInt32LE(uncompressedSize)
            central.appendUInt16LE(UInt16(nameData.count))
            central.appendUInt16LE(0) // extra field length
            central.appendUInt16LE(0) // file comment length
            central.appendUInt16LE(0) // disk number start
            central.appendUInt16LE(0) // internal file attributes
            central.appendUInt32LE(0) // external file attributes
            central.appendUInt32LE(localHeaderOffset)
            central.append(nameData)
            centralDirectory.append(central)
            writtenEntries += 1
        }

        let centralDirectoryOffset = archive.count
        let totalSize = archive.count + centralDirectory.count + ZIPFormat.endOfCentralDirectoryLength
        guard writtenEntries <= Int(UInt16.max),
              centralDirectoryOffset <= Int(UInt32.max),
              centralDirectory.count <= Int(UInt32.max),
              totalSize <= Int(UInt32.max) else {
            throw AppError.exportFailed
        }

        archive.append(centralDirectory)
        archive.appendUInt32LE(ZIPFormat.endOfCentralDirectorySignature)
        archive.appendUInt16LE(0) // number of this disk
        archive.appendUInt16LE(0) // disk with the start of the central directory
        archive.appendUInt16LE(UInt16(writtenEntries))
        archive.appendUInt16LE(UInt16(writtenEntries))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(UInt32(centralDirectoryOffset))
        archive.appendUInt16LE(0) // archive comment length
        try archive.write(to: outputURL, options: [.atomic])
        progress(1)
    }

    /// Raw DEFLATE (RFC 1951). Apple's `COMPRESSION_ZLIB` emits a raw deflate
    /// stream with no zlib header or trailer, which is exactly ZIP method 8.
    /// Returns nil when the data does not compress (the caller then stores it).
    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count
        var output = Data(count: capacity)
        let written: Int = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_encode_buffer(
                    destinationBase,
                    capacity,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0, written < data.count else { return nil }
        return Data(output.prefix(written))
    }
}

enum SimpleZIPReader {
    static func read(url: URL) throws -> [ZIPEntrySource] {
        try read(archive: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    static func read(archive: Data) throws -> [ZIPEntrySource] {
        guard archive.count >= ZIPFormat.endOfCentralDirectoryLength else {
            throw ZIPError.malformed("archive is too small to be a ZIP file")
        }
        let endOffset = try endOfCentralDirectoryOffset(in: archive)

        guard try archive.zipUInt16(at: endOffset + 4) == 0,
              try archive.zipUInt16(at: endOffset + 6) == 0 else {
            throw ZIPError.unsupported("multi-disk archives are not supported")
        }
        let totalEntries = try archive.zipUInt16(at: endOffset + 10)
        let centralDirectorySize = try archive.zipUInt32(at: endOffset + 12)
        let centralDirectoryOffset = try archive.zipUInt32(at: endOffset + 16)
        guard totalEntries != 0xFFFF,
              centralDirectorySize != 0xFFFF_FFFF,
              centralDirectoryOffset != 0xFFFF_FFFF else {
            throw ZIPError.unsupported("ZIP64 archives are not supported")
        }

        var cursor = Int(centralDirectoryOffset)
        var entries: [ZIPEntrySource] = []
        entries.reserveCapacity(Int(totalEntries))

        for _ in 0..<Int(totalEntries) {
            try Task.checkCancellation()
            guard try archive.zipUInt32(at: cursor) == ZIPFormat.centralHeaderSignature else {
                throw ZIPError.malformed("bad central directory header")
            }
            let flags = try archive.zipUInt16(at: cursor + 8)
            let method = try archive.zipUInt16(at: cursor + 10)
            let crc = try archive.zipUInt32(at: cursor + 16)
            let compressedSize = try archive.zipUInt32(at: cursor + 20)
            let uncompressedSize = try archive.zipUInt32(at: cursor + 24)
            let nameLength = Int(try archive.zipUInt16(at: cursor + 28))
            let extraLength = Int(try archive.zipUInt16(at: cursor + 30))
            let commentLength = Int(try archive.zipUInt16(at: cursor + 32))
            let localHeaderOffset = try archive.zipUInt32(at: cursor + 42)
            let nameData = try archive.zipSlice(at: cursor + ZIPFormat.centralHeaderLength, count: nameLength)
            cursor += ZIPFormat.centralHeaderLength + nameLength + extraLength + commentLength

            if flags & 0x0001 != 0 {
                throw ZIPError.unsupported("encrypted entries are not supported")
            }
            if flags & 0x0008 != 0 {
                throw ZIPError.unsupported("entries written with a data descriptor are not supported")
            }
            guard compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  localHeaderOffset != 0xFFFF_FFFF else {
                throw ZIPError.unsupported("ZIP64 entries are not supported")
            }
            guard method == ZIPFormat.methodStore || method == ZIPFormat.methodDeflate else {
                throw ZIPError.unsupported("compression method \(method) is not supported")
            }

            let name = String(decoding: nameData, as: UTF8.self)
            if name.hasSuffix("/") { continue }

            let local = Int(localHeaderOffset)
            guard try archive.zipUInt32(at: local) == ZIPFormat.localHeaderSignature else {
                throw ZIPError.malformed("bad local file header for \(name)")
            }
            // The local header's own name/extra lengths are authoritative: they may
            // differ from the central directory copy.
            let localNameLength = Int(try archive.zipUInt16(at: local + 26))
            let localExtraLength = Int(try archive.zipUInt16(at: local + 28))
            let payload = try archive.zipSlice(
                at: local + ZIPFormat.localHeaderLength + localNameLength + localExtraLength,
                count: Int(compressedSize)
            )

            let decoded = method == ZIPFormat.methodStore
                ? payload
                : try inflate(payload, uncompressedSize: Int(uncompressedSize))
            guard decoded.count == Int(uncompressedSize) else {
                throw ZIPError.malformed("size mismatch for \(name)")
            }
            guard CRC32.checksum(decoded) == crc else {
                throw ZIPError.malformed("checksum mismatch for \(name)")
            }
            entries.append(ZIPEntrySource(name: name, data: decoded))
        }

        return entries
    }

    private static func endOfCentralDirectoryOffset(in archive: Data) throws -> Int {
        // The archive comment can be up to 65535 bytes, so the record starts at
        // most 65535 + 22 bytes from the end.
        let lowerBound = max(0, archive.count - 66_000)
        var index = archive.count - ZIPFormat.endOfCentralDirectoryLength
        while index >= lowerBound {
            if try archive.zipUInt32(at: index) == ZIPFormat.endOfCentralDirectorySignature {
                return index
            }
            index -= 1
        }
        throw ZIPError.malformed("end of central directory record not found")
    }

    /// Raw DEFLATE inflate. ZIP stores the real uncompressed size in the header,
    /// so a single fixed-size destination buffer is enough.
    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw ZIPError.malformed("missing deflate payload") }
        var output = Data(count: uncompressedSize)
        let written: Int = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationBase,
                    uncompressedSize,
                    sourceBase,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else {
            throw ZIPError.malformed("could not inflate entry")
        }
        return output
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

    func zipUInt16(at offset: Int) throws -> UInt16 {
        let start = startIndex + offset
        guard offset >= 0, start >= startIndex, start + 2 <= endIndex else {
            throw ZIPError.malformed("unexpected end of archive")
        }
        return UInt16(self[start]) | (UInt16(self[start + 1]) << 8)
    }

    func zipUInt32(at offset: Int) throws -> UInt32 {
        let start = startIndex + offset
        guard offset >= 0, start >= startIndex, start + 4 <= endIndex else {
            throw ZIPError.malformed("unexpected end of archive")
        }
        return UInt32(self[start])
            | (UInt32(self[start + 1]) << 8)
            | (UInt32(self[start + 2]) << 16)
            | (UInt32(self[start + 3]) << 24)
    }

    func zipSlice(at offset: Int, count: Int) throws -> Data {
        let start = startIndex + offset
        guard offset >= 0, count >= 0, start >= startIndex, start + count <= endIndex else {
            throw ZIPError.malformed("unexpected end of archive")
        }
        return Data(self[start..<(start + count)])
    }
}
