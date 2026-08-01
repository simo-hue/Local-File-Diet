import Foundation

protocol TemporaryFileStoring {
    func workingDirectory() async throws -> URL
    func outputsDirectory() async throws -> URL
    func stagingDirectory() async throws -> URL
    func copyIntoWorkingDirectory(from sourceURL: URL, preferredFilename: String?) async throws -> URL
    func makeOutputURL(originalFilename: String, extension outputExtension: String) async throws -> URL
    func cleanupOlderThan24Hours() async
    func clearAll() async throws
}

actor TemporaryFileStore: TemporaryFileStoring {
    private let fileManager: FileManager
    private let baseCachesURL: URL
    private let tmpURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.baseCachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.tmpURL = fileManager.temporaryDirectory
    }

    func workingDirectory() async throws -> URL {
        try directory(named: "Working", under: baseCachesURL)
    }

    func outputsDirectory() async throws -> URL {
        try directory(named: "Outputs", under: baseCachesURL)
    }

    func stagingDirectory() async throws -> URL {
        try directory(named: "ImportStaging", under: tmpURL)
    }

    func copyIntoWorkingDirectory(from sourceURL: URL, preferredFilename: String? = nil) async throws -> URL {
        let directoryURL = try await workingDirectory()
        let filename = sanitizedFilename(preferredFilename ?? sourceURL.lastPathComponent)
        let destinationURL = directoryURL.appendingPathComponent("\(UUID().uuidString)-\(filename)")
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        try protectCacheFile(destinationURL)
        return destinationURL
    }

    func makeOutputURL(originalFilename: String, extension outputExtension: String) async throws -> URL {
        let directoryURL = try await outputsDirectory()
        let base = URL(fileURLWithPath: originalFilename).deletingPathExtension().lastPathComponent
        let cleanBase = sanitizedFilename(base)
        let fileExtension = outputExtension.isEmpty ? "bin" : outputExtension
        return directoryURL.appendingPathComponent("\(cleanBase)-compressed-\(shortID()).\(fileExtension)")
    }

    func cleanupOlderThan24Hours() async {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for directory in [try? await workingDirectory(), try? await outputsDirectory(), try? await stagingDirectory()].compactMap({ $0 }) {
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                if (values?.contentModificationDate ?? .distantFuture) < cutoff {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    func clearAll() async throws {
        for directory in [try? await workingDirectory(), try? await outputsDirectory(), try? await stagingDirectory()].compactMap({ $0 }) {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
        clearSharedInbox()
    }

    /// Settings says "Temporary files cleared", so it has to mean all of them.
    /// Files handed over by the share extension live in the app group container,
    /// not in this app's own caches, and were being left behind - a full copy of
    /// whatever the user shared, sitting there after they asked for it to go.
    private func clearSharedInbox() {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier
        ) else { return }
        let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
        guard fileManager.fileExists(atPath: incoming.path) else { return }
        try? fileManager.removeItem(at: incoming)
    }

    private func directory(named name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
        }
        return url
    }

    private func protectCacheFile(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    private func sanitizedFilename(_ filename: String) -> String {
        let fallback = "file"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_ "))
        let scalars = filename.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }

    private func shortID() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}

