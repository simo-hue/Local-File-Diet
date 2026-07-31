import Foundation

/// Packs a finished batch into one ZIP.
///
/// This is the answer to "I have nine compressed files on my phone and one
/// attachment slot". `SimpleZIPWriter` does real DEFLATE, so the archive is a
/// genuine single-file deliverable rather than a container.
///
/// Every function here is `nonisolated async`, which under Swift 6 means a call
/// from the main actor leaves the main actor: reading the outputs and deflating
/// them never happens on the UI thread. Everything crossing that boundary is
/// `Sendable`, including the destination URL, which the caller obtains from the
/// file store before calling in.
enum BatchArchive {
    struct Entry: Sendable, Hashable {
        /// The name the user should see inside the archive.
        let filename: String
        /// Where the bytes are right now.
        let url: URL
    }

    /// Two files called `photo-compressed.jpg` cannot both be `photo-compressed.jpg`
    /// inside one archive; some unzippers silently keep the last one. Suffix the
    /// duplicates instead.
    static func uniqueNames(for filenames: [String]) -> [String] {
        var seen: [String: Int] = [:]
        var result: [String] = []
        result.reserveCapacity(filenames.count)
        for filename in filenames {
            let base = filename.isEmpty ? "file" : filename
            let count = (seen[base.lowercased()] ?? 0) + 1
            seen[base.lowercased()] = count
            if count == 1 {
                result.append(base)
            } else {
                let url = URL(fileURLWithPath: base)
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                result.append(ext.isEmpty ? "\(stem)-\(count)" : "\(stem)-\(count).\(ext)")
            }
        }
        return result
    }

    /// Reads each output and writes one archive at `outputURL`.
    ///
    /// `progress` runs from 0 to 1 across both halves of the job (reading, then
    /// deflating) so the UI can show something honest during the deflate, which
    /// is the slow part.
    static func write(
        entries: [Entry],
        to outputURL: URL,
        fileManager: FileManager = .default,
        progress: @Sendable (Double) -> Void = { _ in }
    ) throws -> URL {
        guard !entries.isEmpty else { throw AppError.exportFailed }
        let names = uniqueNames(for: entries.map(\.filename))

        var sources: [ZIPEntrySource] = []
        sources.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: entry.url.path) else { continue }
            let data = try Data(contentsOf: entry.url, options: [.mappedIfSafe])
            sources.append(ZIPEntrySource(name: names[index], data: data))
            progress(Double(index + 1) / Double(entries.count) * 0.35)
        }
        guard !sources.isEmpty else { throw AppError.exportFailed }

        try SimpleZIPWriter.write(entries: sources, to: outputURL) { fraction in
            progress(0.35 + fraction * 0.65)
        }
        progress(1)
        return outputURL
    }

    /// `async` so that calling it from a view leaves the main actor.
    static func writeOffMainActor(
        entries: [Entry],
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try write(entries: entries, to: outputURL, progress: progress)
    }

    /// The filename the archive itself should carry.
    static func archiveName(for entries: [Entry], date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "local-file-diet-\(entries.count)-files-\(formatter.string(from: date))"
    }
}
