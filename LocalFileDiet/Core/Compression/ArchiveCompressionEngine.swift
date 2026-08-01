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
                    throw ZIPError.refused(.noFiles)
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
                // rather than failing the whole operation. The reason is kept
                // rather than thrown away - "encrypted", "written with a data
                // descriptor" and "unpacks to more than a phone can take" are
                // three different answers, and a warning that lists all of them
                // is only ever right by accident.
                let refusal = ArchiveRefusal.from(error)
                AppLogger.compression.info(
                    "zip_repack_skipped reason=\(refusal.logName, privacy: .public) detail=\(String(describing: error), privacy: .private)"
                )
                warnings.append(.zipCouldNotRepack(refusal))
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
    /// Formats that carry their own compression, so deflating them again buys
    /// nothing. Used both to set expectations for a whole file and, per entry,
    /// to skip a deflate pass that would only be thrown away.
    static let compressedExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "avif", "tif", "tiff",
        "mp4", "mov", "m4v", "hevc", "avi", "mkv", "webm",
        "mp3", "aac", "m4a", "ogg", "opus", "flac",
        "zip", "7z", "rar", "gz", "bz2", "xz", "tgz",
        "docx", "xlsx", "pptx", "epub", "ipa", "apk"
    ]

    /// True when an entry's own name says it is already a compressed format.
    static func isAlreadyCompressed(entryName: String) -> Bool {
        compressedExtensions.contains(URL(fileURLWithPath: entryName).pathExtension.lowercased())
    }

    static func isAlreadyCompressed(_ input: CompressionInput) -> Bool {
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

    /// The engine already knows exactly why a re-pack was refused, so say that
    /// rather than reciting every possible cause at everyone. The old copy named
    /// encryption and ZIP64 for archives that had neither - most commonly a
    /// Finder-made archive, which is refused for an entirely different reason.
    /// Stable identity for the warning above. The message varies with the cause,
    /// the id does not - `OutputGuard` and the tests match on this.
    static let zipCouldNotRepackID = "zipCouldNotRepack"

    static func zipCouldNotRepack(_ refusal: ArchiveRefusal) -> CompressionWarning {
        CompressionWarning(
            id: zipCouldNotRepackID,
            severity: .info,
            title: "Contents left untouched",
            message: refusal.explanation
        )
    }

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
    /// Same meaning as `.unsupported` - the file may be perfectly valid, we are
    /// the ones saying no - but it names the cause instead of describing it, so
    /// the log and the user-facing copy can each be specific.
    case refused(ArchiveRefusal)
}

/// Why an archive was wrapped as-is instead of re-packed.
///
/// These are not interchangeable. An encrypted archive, one written with a
/// trailing data descriptor, and one that would unpack to more than a phone can
/// take are three different things that happen to reach the same fallback, and
/// the difference is exactly what a warning has to be able to say.
enum ArchiveRefusal: Sendable, Equatable {
    /// Entries are password-protected.
    case encrypted
    /// Sizes live in a trailing data descriptor rather than in the headers.
    /// This is what a ZIP written as a stream looks like, and it is by far the
    /// most common reason a re-pack is skipped.
    case dataDescriptor
    /// Sizes or offsets past 4 GB.
    case zip64
    /// Something other than store or deflate.
    case method(UInt16)
    /// Spanned across several volumes.
    case multiDisk
    /// More files inside than we walk.
    case tooManyEntries(count: Int, limit: Int)
    /// One entry on its own declares more than the per-entry cap.
    case entryTooLarge(declaredBytes: Int, limit: Int)
    /// The archive as a whole declares more than the unpack budget.
    case unpacksTooLarge(declaredBytes: Int, budget: Int)
    /// Nothing inside but directory markers.
    case noFiles
    /// Truncated, wrong checksum, headers that do not agree: broken input.
    case damaged
    /// Anything else, including a read that failed before the ZIP was parsed.
    case unreadable

    /// Carries no filename or other content, so it is safe to log in the clear.
    var logName: String {
        switch self {
        case .encrypted: "encrypted"
        case .dataDescriptor: "dataDescriptor"
        case .zip64: "zip64"
        case .method(let method): "method\(method)"
        case .multiDisk: "multiDisk"
        case .tooManyEntries: "tooManyEntries"
        case .entryTooLarge: "entryTooLarge"
        case .unpacksTooLarge: "unpacksTooLarge"
        case .noFiles: "noFiles"
        case .damaged: "damaged"
        case .unreadable: "unreadable"
        }
    }

    /// Plain-English reason shown on the result screen. Every one of these ends
    /// in the same outcome - the archive was wrapped as-is - so each says what
    /// was actually wrong rather than listing causes that do not apply.
    var explanation: String {
        let wrapped = "It was wrapped as-is instead of being re-packed."
        switch self {
        case .encrypted:
            return "This archive is password-protected, so its contents cannot be read. \(wrapped)"
        case .dataDescriptor:
            return "This archive was written in a streaming style we cannot re-read - the Finder and many websites produce these. \(wrapped)"
        case .zip64, .multiDisk:
            return "This archive uses an extended ZIP format we do not read. \(wrapped)"
        case .method:
            return "This archive was packed with a compression method we do not read. \(wrapped)"
        case .tooManyEntries(let count, _):
            return "This archive holds \(count) files, more than we unpack on a phone. \(wrapped)"
        case .entryTooLarge, .unpacksTooLarge:
            return "This archive would unpack to far more than is safe to hold on a phone. \(wrapped)"
        case .noFiles:
            return "This archive has no files inside it to re-pack. \(wrapped)"
        case .damaged:
            return "This archive looks damaged, so its contents were left untouched. \(wrapped)"
        case .unreadable:
            return "This archive could not be read. \(wrapped)"
        }
    }

    static func from(_ error: Error) -> ArchiveRefusal {
        guard let zipError = error as? ZIPError else { return .unreadable }
        switch zipError {
        case .refused(let refusal): return refusal
        case .malformed: return .damaged
        case .unsupported: return .unreadable
        }
    }
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

/// Raw DEFLATE (RFC 1951) driven a chunk at a time. Apple's `COMPRESSION_ZLIB`
/// emits a raw deflate stream with no zlib header or trailer, which is exactly
/// ZIP method 8.
///
/// `compression_encode_buffer` and `compression_decode_buffer` both want a
/// destination large enough for the whole result before they start, which is
/// what turns a big entry - or a decompression bomb - into a memory problem.
/// The streaming API hands the result over one chunk at a time instead, so the
/// peak cost is this buffer rather than the payload.
enum RawDeflate {
    /// Large enough that the per-call overhead disappears, small enough to be
    /// irrelevant next to anything worth compressing.
    static let chunkSize = 256 * 1024

    /// Feeds all of `source` through the stream, handing every chunk of output to
    /// `emit` together with how much of `source` has been consumed so far.
    /// `emit` may throw to abandon the job.
    ///
    /// The `Data` handed to `emit` borrows the internal buffer and is only valid
    /// for the duration of the call: write it or copy it, do not keep it.
    static func run(
        operation: compression_stream_operation,
        source: Data,
        emit: (Data, Int) throws -> Void
    ) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZIPError.malformed("could not start the compression stream")
        }
        defer { compression_stream_destroy(stream) }

        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }
        guard let output = buffer.baseAddress else {
            throw ZIPError.malformed("could not allocate a compression buffer")
        }

        try source.withUnsafeBytes { rawSource in
            guard let input = rawSource.bindMemory(to: UInt8.self).baseAddress else {
                throw ZIPError.malformed("missing compression input")
            }
            stream.pointee.src_ptr = input
            stream.pointee.src_size = rawSource.count
            var remaining = rawSource.count
            var status = COMPRESSION_STATUS_OK
            repeat {
                stream.pointee.dst_ptr = output
                stream.pointee.dst_size = chunkSize
                status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw ZIPError.malformed("the compressed stream is damaged")
                }
                let produced = chunkSize - stream.pointee.dst_size
                if produced > 0 {
                    let chunk = Data(
                        bytesNoCopy: UnsafeMutableRawPointer(output),
                        count: produced,
                        deallocator: .none
                    )
                    try emit(chunk, rawSource.count - stream.pointee.src_size)
                }
                // A pass that neither consumes nor produces anything would spin
                // forever, so treat standing still as a broken stream.
                guard status == COMPRESSION_STATUS_END
                    || produced > 0
                    || stream.pointee.src_size < remaining else {
                    throw ZIPError.malformed("the compressed stream stalled")
                }
                remaining = stream.pointee.src_size
            } while status == COMPRESSION_STATUS_OK
        }
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
            // Mapped, not read: the payload stays file-backed, so a 320 MB input
            // costs page cache rather than a 320 MB allocation. `BatchArchive`
            // has always done this; this path simply did not.
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            entries.append(ZIPEntrySource(name: fileURL.lastPathComponent, data: data))
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            dates.append((attributes?[.modificationDate] as? Date) ?? Date())
        }
        try write(entries: entries, modificationDates: dates, to: outputURL, progress: progress)
    }

    /// Writes pre-loaded entries, preserving their (normalised) relative paths.
    static func write(entries: [ZIPEntrySource], to outputURL: URL, progress: (Double) -> Void = { _ in }) throws {
        try write(entries: entries, modificationDates: [], to: outputURL, progress: progress)
    }

    /// Thrown out of the deflate stream the moment the entry stops getting
    /// smaller, so the writer can rewind and store it instead.
    private struct DeflateIsNotHelping: Error {}

    private static func write(
        entries: [ZIPEntrySource],
        modificationDates: [Date],
        to outputURL: URL,
        progress: (Double) -> Void
    ) throws {
        // Built beside the destination and moved into place, so a cancelled or
        // failed run never leaves a half-written archive where callers expect a
        // finished one. This is what `Data.write(options: .atomic)` used to give
        // us before the archive stopped fitting in a `Data`.
        // Not hidden: `TemporaryFileStore.cleanupOlderThan24Hours` skips hidden
        // files, and one left behind by a crash should still get swept up.
        //
        // The scratch name is its own, not "<destination>.part": a filename may
        // be 255 bytes, and appending five more to a 251-byte destination fails
        // a write that would otherwise have worked. This one is always 51 bytes
        // whatever it is built beside.
        let fileManager = FileManager.default
        let partURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("zip-write-\(UUID().uuidString).part")
        guard fileManager.createFile(atPath: partURL.path, contents: nil) else {
            throw AppError.exportFailed
        }
        do {
            let handle = try FileHandle(forWritingTo: partURL)
            do {
                try writeArchive(
                    entries: entries,
                    modificationDates: modificationDates,
                    to: handle,
                    progress: progress
                )
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try fileManager.moveItem(at: partURL, to: outputURL)
        } catch {
            try? fileManager.removeItem(at: partURL)
            throw error
        }
        progress(1)
    }

    /// Streams the whole archive through `handle`: local header and payload per
    /// entry, then the central directory, then the end of central directory
    /// record. Nothing but the central directory is ever held in memory, so the
    /// peak cost is a 256 KB chunk rather than a second copy of the input.
    private static func writeArchive(
        entries: [ZIPEntrySource],
        modificationDates: [Date],
        to handle: FileHandle,
        progress: (Double) -> Void
    ) throws {
        var centralDirectory = Data()
        var writtenEntries = 0
        var offset = 0
        let fallbackDate = Date()

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(entries.count))

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
                  offset <= Int(UInt32.max) else {
                throw AppError.exportFailed
            }

            // Big entries take seconds; report inside them too, but only when the
            // overall figure has actually moved.
            var reported = Double(index) / Double(entries.count)
            func report(_ entryFraction: Double) {
                let overall = (Double(index) + entryFraction) / Double(entries.count)
                guard overall - reported >= 0.005 else { return }
                reported = overall
                progress(overall)
            }

            let crc = CRC32.checksum(raw)
            let localHeaderOffset = UInt32(offset)
            let date = modificationDates.indices.contains(index) ? modificationDates[index] : fallbackDate
            let stamp = ZIPFormat.dosDateTime(from: date)
            let uncompressedSize = UInt32(raw.count)

            // The local header goes down twice: once with a placeholder compressed
            // size so the payload can stream straight out behind it, then again
            // once the deflate has settled the method and the real size. Only the
            // three fields that could not be known up front change between the two.
            try handle.write(contentsOf: localHeaderFields(
                method: ZIPFormat.methodDeflate,
                stamp: stamp,
                crc: crc,
                compressedSize: 0,
                uncompressedSize: uncompressedSize,
                nameLength: nameData.count
            ))
            try handle.write(contentsOf: nameData)
            offset += ZIPFormat.localHeaderLength + nameData.count
            let payloadOffset = offset

            var method = ZIPFormat.methodDeflate
            var compressedSize = 0
            // A JPEG or an MP4 will not deflate, and its own name says so. Skipping
            // the pass keeps the common incompressible entry off the "deflate it
            // all, then throw it away" path without ever guessing about an entry
            // whose type we do not recognise.
            let deflatedSize = ArchiveCompressionEngine.isAlreadyCompressed(entryName: name)
                ? nil
                : try deflate(raw, into: handle, report: report)
            if let deflatedSize {
                compressedSize = deflatedSize
            } else {
                // Deflate did not help. Rewind over whatever it managed to write
                // and store the entry instead.
                try handle.truncate(atOffset: UInt64(payloadOffset))
                try handle.seek(toOffset: UInt64(payloadOffset))
                method = ZIPFormat.methodStore
                compressedSize = try store(raw, into: handle, report: report)
            }
            guard compressedSize <= Int(UInt32.max) else { throw AppError.exportFailed }
            offset = payloadOffset + compressedSize

            try handle.seek(toOffset: UInt64(localHeaderOffset))
            try handle.write(contentsOf: localHeaderFields(
                method: method,
                stamp: stamp,
                crc: crc,
                compressedSize: UInt32(compressedSize),
                uncompressedSize: uncompressedSize,
                nameLength: nameData.count
            ))
            try handle.seek(toOffset: UInt64(offset))

            var central = Data()
            central.appendUInt32LE(ZIPFormat.centralHeaderSignature)
            central.appendUInt16LE(ZIPFormat.versionMadeBy)
            central.appendUInt16LE(ZIPFormat.versionNeeded)
            central.appendUInt16LE(ZIPFormat.utf8NameFlag)
            central.appendUInt16LE(method)
            central.appendUInt16LE(stamp.time)
            central.appendUInt16LE(stamp.date)
            central.appendUInt32LE(crc)
            central.appendUInt32LE(UInt32(compressedSize))
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

        let centralDirectoryOffset = offset
        let totalSize = offset + centralDirectory.count + ZIPFormat.endOfCentralDirectoryLength
        guard writtenEntries <= Int(UInt16.max),
              centralDirectoryOffset <= Int(UInt32.max),
              centralDirectory.count <= Int(UInt32.max),
              totalSize <= Int(UInt32.max) else {
            throw AppError.exportFailed
        }

        try handle.write(contentsOf: centralDirectory)
        var end = Data()
        end.appendUInt32LE(ZIPFormat.endOfCentralDirectorySignature)
        end.appendUInt16LE(0) // number of this disk
        end.appendUInt16LE(0) // disk with the start of the central directory
        end.appendUInt16LE(UInt16(writtenEntries))
        end.appendUInt16LE(UInt16(writtenEntries))
        end.appendUInt32LE(UInt32(centralDirectory.count))
        end.appendUInt32LE(UInt32(centralDirectoryOffset))
        end.appendUInt16LE(0) // archive comment length
        try handle.write(contentsOf: end)
    }

    /// The 30 fixed bytes of a local file header. The filename follows it and is
    /// written separately, because it never changes between the placeholder pass
    /// and the final one.
    private static func localHeaderFields(
        method: UInt16,
        stamp: (time: UInt16, date: UInt16),
        crc: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        nameLength: Int
    ) -> Data {
        var header = Data()
        header.reserveCapacity(ZIPFormat.localHeaderLength)
        header.appendUInt32LE(ZIPFormat.localHeaderSignature)
        header.appendUInt16LE(ZIPFormat.versionNeeded)
        header.appendUInt16LE(ZIPFormat.utf8NameFlag)
        header.appendUInt16LE(method)
        header.appendUInt16LE(stamp.time)
        header.appendUInt16LE(stamp.date)
        header.appendUInt32LE(crc)
        header.appendUInt32LE(compressedSize)
        header.appendUInt32LE(uncompressedSize)
        header.appendUInt16LE(UInt16(nameLength))
        header.appendUInt16LE(0) // extra field length
        return header
    }

    /// How much deflate output is held in memory before any of it reaches the
    /// disk. An entry whose whole compressed form fits in here is decided
    /// before a single byte is written, which is nearly every entry there is.
    static let deflateDecisionBytes = 4 * 1024 * 1024

    /// Deflates `source` into `handle`, giving up only once the output has grown
    /// past the input - at which point storing is provably the better deal and
    /// the caller rewinds. Returns the bytes written, or nil when it gave up.
    ///
    /// The first `deflateDecisionBytes` of output are buffered rather than
    /// written, so any entry whose compressed form fits in the buffer - nearly
    /// every entry there is - never touches the disk twice.
    ///
    /// There is deliberately NO "has it saved enough yet?" shortcut at the
    /// decision point. Compressibility is not evenly spread: an entry that opens
    /// with an embedded JPEG and continues with a megabyte of text saves nothing
    /// over its first few megabytes and a great deal overall. Judging the whole
    /// entry by its head stored those entries whole, which is a failure of the
    /// one thing this engine is for. The only safe early exit is the one below,
    /// which fires when the deflate is genuinely expanding the data. Entries that
    /// are already in a compressed format are skipped by name before we get here,
    /// so the common incompressible case never pays for a full pass.
    private static func deflate(
        _ source: Data,
        into handle: FileHandle,
        report: (Double) -> Void
    ) throws -> Int? {
        guard !source.isEmpty else { return nil }
        let budget = source.count
        var head = Data()
        var flushed = false
        var written = 0
        do {
            try RawDeflate.run(operation: COMPRESSION_STREAM_ENCODE, source: source) { chunk, consumed in
                try Task.checkCancellation()
                guard written + chunk.count < budget else { throw DeflateIsNotHelping() }
                if !flushed {
                    if written + chunk.count <= deflateDecisionBytes {
                        head.append(chunk)
                        written += chunk.count
                        report(Double(consumed) / Double(budget))
                        return
                    }
                    try handle.write(contentsOf: head)
                    head = Data()
                    flushed = true
                }
                try handle.write(contentsOf: chunk)
                written += chunk.count
                report(Double(consumed) / Double(budget))
            }
        } catch is DeflateIsNotHelping {
            return nil
        }
        // The whole stream fitted in the buffer, so its final size was known
        // before anything was written.
        if !flushed {
            try handle.write(contentsOf: head)
        }
        return written
    }

    /// Copies `source` into `handle` a chunk at a time, so a stored entry never
    /// needs a second copy of itself in memory.
    private static func store(
        _ source: Data,
        into handle: FileHandle,
        report: (Double) -> Void
    ) throws -> Int {
        var written = 0
        while written < source.count {
            try Task.checkCancellation()
            let start = source.startIndex + written
            let end = min(start + RawDeflate.chunkSize, source.endIndex)
            try handle.write(contentsOf: source[start..<end])
            written += end - start
            report(Double(written) / Double(source.count))
        }
        return written
    }
}

enum SimpleZIPReader {
    // A ZIP header can claim any uncompressed size it likes, and a genuinely
    // expanding stream really does produce those bytes. iOS 17 still runs on
    // 3 GB devices - iPhone XR, iPhone SE (2nd generation) - where jetsam kills
    // a foreground app somewhere around 1.3 GB, and jetsam is not an error we
    // can catch: the app simply disappears. Entries are streamed to disk rather
    // than held in memory (see `inflate`), but scratch space on a phone is
    // finite too, so the unpack is bounded four ways. Past any of them we
    // refuse, and `ArchiveCompressionEngine` wraps the archive as it stands.
    //
    // Every one of these is checked against the central directory BEFORE a byte
    // is unpacked. Measured on the old order, which checked the running total as
    // it went: an archive of 3000 half-megabyte entries declaring 1.5 GB was
    // refused only after 0.9 seconds and 238 MB of scratch writes. It is now
    // refused having read nothing but its own index.

    /// No single file inside an archive may unpack to more than this.
    static let maxEntryUncompressedBytes = 512 * 1024 * 1024
    /// Nor may the archive as a whole. Beyond this, unpacking and re-deflating
    /// on a phone costs more time and scratch space than the result is worth.
    static let maxTotalUncompressedBytes = 1024 * 1024 * 1024
    /// And nothing may expand by more than this much relative to the archive's
    /// own size on disk. This is what stops the hand-made bomb: 1.2 MB claiming
    /// 1.2 GB is refused before a byte of it is allocated.
    static let maxExpansionRatio = 200
    /// Below this the ratio does not apply: a few kilobytes of zipped text
    /// honestly unpacks to far more than 200 times its size.
    static let minimumExpansionAllowance = 32 * 1024 * 1024
    /// How much decoded payload is allowed to stay in memory before entries
    /// start going to scratch files instead. Small archives - which is nearly
    /// all of them - never touch the disk; a big one trades speed for a
    /// footprint that cannot get the app killed.
    static let maxDecodedBytesInMemory = 128 * 1024 * 1024
    /// And no archive may hold more files than this, however small they are.
    /// The three size caps above say nothing about how many pieces the bytes
    /// arrive in, and every entry costs a header parse, an inflate and - once
    /// the memory allowance above is spent - a scratch file of its own.
    /// Measured: 65534 four-kilobyte entries clear all three size caps and still
    /// take about 7 seconds and 134 MB of scratch writes on a Mac, which is worse
    /// on a phone - but that is a slow operation the user asked for, with progress
    /// and a cancel button, not a crash. The limit is therefore the format's own:
    /// the end-of-central-directory record counts entries in 16 bits, and anything
    /// past that is ZIP64, which we refuse separately. A tighter bound was tried at
    /// 8192 and turned out to reject perfectly ordinary archives - an exported
    /// photo library or a source tree runs to tens of thousands of files - which
    /// traded a real feature for a hypothetical.
    static let maxEntryCount = 65_535

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
            throw ZIPError.refused(.multiDisk)
        }
        let totalEntries = try archive.zipUInt16(at: endOffset + 10)
        let centralDirectorySize = try archive.zipUInt32(at: endOffset + 12)
        let centralDirectoryOffset = try archive.zipUInt32(at: endOffset + 16)
        guard totalEntries != 0xFFFF,
              centralDirectorySize != 0xFFFF_FFFF,
              centralDirectoryOffset != 0xFFFF_FFFF else {
            throw ZIPError.refused(.zip64)
        }

        // How many files the archive says it holds is the one thing that is free
        // to check, so it is checked before the directory is even walked.
        guard Int(totalEntries) <= maxEntryCount else {
            throw ZIPError.refused(.tooManyEntries(count: Int(totalEntries), limit: maxEntryCount))
        }

        let unpackBudget = min(
            maxTotalUncompressedBytes,
            max(minimumExpansionAllowance, archive.count * maxExpansionRatio)
        )
        let directory = try centralDirectory(
            in: archive,
            at: Int(centralDirectoryOffset),
            count: Int(totalEntries)
        )

        // What the archive says it unpacks to, settled before anything is
        // unpacked. Checking this as the entries went by meant a large or
        // hostile archive could spend most of the budget in scratch I/O and only
        // then be turned away.
        let declaredTotal = directory.reduce(0) { $0 + $1.uncompressedSize }
        guard declaredTotal <= unpackBudget else {
            throw ZIPError.refused(.unpacksTooLarge(declaredBytes: declaredTotal, budget: unpackBudget))
        }

        var entries: [ZIPEntrySource] = []
        entries.reserveCapacity(directory.count)
        var unpacked = 0
        var memoryAllowance = maxDecodedBytesInMemory

        for entry in directory {
            try Task.checkCancellation()
            let local = entry.localHeaderOffset
            guard try archive.zipUInt32(at: local) == ZIPFormat.localHeaderSignature else {
                throw ZIPError.malformed("bad local file header for \(entry.name)")
            }
            // The local header's own name/extra lengths are authoritative: they may
            // differ from the central directory copy.
            let localNameLength = Int(try archive.zipUInt16(at: local + 26))
            let localExtraLength = Int(try archive.zipUInt16(at: local + 28))
            let payload = try archive.zipSlice(
                at: local + ZIPFormat.localHeaderLength + localNameLength + localExtraLength,
                count: entry.compressedSize
            )

            let decoded = entry.method == ZIPFormat.methodStore
                ? payload
                : try inflate(payload, uncompressedSize: entry.uncompressedSize, memoryAllowance: &memoryAllowance)
            guard decoded.count == entry.uncompressedSize else {
                throw ZIPError.malformed("size mismatch for \(entry.name)")
            }
            guard CRC32.checksum(decoded) == entry.crc else {
                throw ZIPError.malformed("checksum mismatch for \(entry.name)")
            }
            // The backstop for a directory that lied: this counts the bytes that
            // actually arrived, not the ones that were promised.
            unpacked += decoded.count
            guard unpacked <= unpackBudget else {
                throw ZIPError.refused(.unpacksTooLarge(declaredBytes: unpacked, budget: unpackBudget))
            }
            entries.append(ZIPEntrySource(name: entry.name, data: decoded))
        }

        return entries
    }

    /// One usable file as the central directory describes it. Directory markers
    /// and anything we refuse to unpack never get this far.
    private struct DirectoryEntry {
        let name: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    /// Walks the central directory only - no payload is touched - so everything
    /// the archive claims about itself is known before any of it is believed.
    private static func centralDirectory(
        in archive: Data,
        at offset: Int,
        count: Int
    ) throws -> [DirectoryEntry] {
        var cursor = offset
        var directory: [DirectoryEntry] = []
        directory.reserveCapacity(count)

        for _ in 0..<count {
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
                throw ZIPError.refused(.encrypted)
            }
            if flags & 0x0008 != 0 {
                throw ZIPError.refused(.dataDescriptor)
            }
            guard compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  localHeaderOffset != 0xFFFF_FFFF else {
                throw ZIPError.refused(.zip64)
            }
            guard method == ZIPFormat.methodStore || method == ZIPFormat.methodDeflate else {
                throw ZIPError.refused(.method(method))
            }

            // Directory markers carry no payload; the tree is implied by the
            // entry names.
            let name = String(decoding: nameData, as: UTF8.self)
            if name.hasSuffix("/") { continue }

            guard Int(uncompressedSize) <= maxEntryUncompressedBytes else {
                throw ZIPError.refused(.entryTooLarge(
                    declaredBytes: Int(uncompressedSize),
                    limit: maxEntryUncompressedBytes
                ))
            }

            directory.append(DirectoryEntry(
                name: name,
                method: method,
                crc: crc,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset)
            ))
        }
        return directory
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

    /// Raw DEFLATE inflate, streamed in fixed-size chunks so nothing ever needs a
    /// destination the size of the whole entry. Entries land in memory while
    /// `memoryAllowance` lasts; after that they are written to a scratch file and
    /// mapped back, which keeps the decoded bytes file-backed and out of the
    /// app's phys_footprint.
    private static func inflate(
        _ data: Data,
        uncompressedSize: Int,
        memoryAllowance: inout Int
    ) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }
        guard !data.isEmpty else { throw ZIPError.malformed("missing deflate payload") }

        if uncompressedSize <= memoryAllowance {
            memoryAllowance -= uncompressedSize
            var output = Data()
            output.reserveCapacity(uncompressedSize)
            try streamInflate(data, uncompressedSize: uncompressedSize) { output.append($0) }
            return output
        }
        return try inflateToScratchFile(data, uncompressedSize: uncompressedSize)
    }

    /// Inflates into a scratch file and maps it back. The file is unlinked as
    /// soon as it is mapped, so the bytes stay reachable through the mapping and
    /// nothing is left behind on disk.
    private static func inflateToScratchFile(_ data: Data, uncompressedSize: Int) throws -> Data {
        let fileManager = FileManager.default
        let scratchURL = fileManager.temporaryDirectory
            .appendingPathComponent("zip-unpack-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: scratchURL.path, contents: nil) else {
            throw ZIPError.malformed("could not make room to unpack the entry")
        }
        defer { try? fileManager.removeItem(at: scratchURL) }

        let handle = try FileHandle(forWritingTo: scratchURL)
        do {
            try streamInflate(data, uncompressedSize: uncompressedSize) { try handle.write(contentsOf: $0) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        return try Data(contentsOf: scratchURL, options: [.mappedIfSafe])
    }

    /// Drives the inflate and enforces the size the header promised as the bytes
    /// arrive, so an entry that expands past its own declaration is stopped
    /// mid-stream rather than after the damage is done.
    private static func streamInflate(
        _ data: Data,
        uncompressedSize: Int,
        consume: (Data) throws -> Void
    ) throws {
        var produced = 0
        try RawDeflate.run(operation: COMPRESSION_STREAM_DECODE, source: data) { chunk, _ in
            try Task.checkCancellation()
            produced += chunk.count
            guard produced <= uncompressedSize else {
                throw ZIPError.malformed("could not inflate entry")
            }
            try consume(chunk)
        }
        guard produced == uncompressedSize else {
            throw ZIPError.malformed("could not inflate entry")
        }
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

    /// Walks the bytes through the buffer rather than through `Data`'s iterator:
    /// entries are now hundreds of megabytes of memory-mapped payload and this
    /// runs over every one of them.
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = table[index] ^ (crc >> 8)
            }
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

    /// A view onto the archive, not a copy of it. A stored entry inside a
    /// memory-mapped archive therefore costs nothing: the slice keeps the
    /// mapping alive and the bytes stay file-backed.
    func zipSlice(at offset: Int, count: Int) throws -> Data {
        let start = startIndex + offset
        guard offset >= 0, count >= 0, start >= startIndex, start + count <= endIndex else {
            throw ZIPError.malformed("unexpected end of archive")
        }
        return self[start..<(start + count)]
    }
}
