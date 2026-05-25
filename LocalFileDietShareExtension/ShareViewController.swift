import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.com.simohue.localfilediet"

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task {
            await handleSharedItems()
        }
    }

    private func handleSharedItems() async {
        do {
            let urls = try await loadIncomingFiles()
            try writeManifest(for: urls)
            openContainingApp()
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            extensionContext?.cancelRequest(withError: error)
        }
    }

    private func loadIncomingFiles() async throws -> [URL] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }

        var copiedURLs: [URL] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if copiedURLs.count >= 1 { break }
                if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    let copied = try await loadFile(from: provider)
                    copiedURLs.append(copied)
                }
            }
        }
        return copiedURLs
    }

    private func loadFile(from provider: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let url else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                    return
                }
                do {
                    let destination = try ShareFileInbox.makeIncomingURL(originalURL: url, appGroupIdentifier: self.appGroupIdentifier)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeManifest(for urls: [URL]) throws {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let manifestURL = incoming.appendingPathComponent("share-manifest.json")
        let manifest = SharedManifest(items: urls.map {
            SharedManifest.Item(fileURL: $0, originalFilename: $0.lastPathComponent, createdAt: Date())
        })
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func openContainingApp() {
        guard let url = URL(string: "localfilediet://share") else { return }
        extensionContext?.open(url)
    }
}

private enum ShareFileInbox {
    static func makeIncomingURL(originalURL: URL, appGroupIdentifier: String) throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let filename = originalURL.lastPathComponent.isEmpty ? "shared-file" : originalURL.lastPathComponent
        return incoming.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }
}

private struct SharedManifest: Codable {
    struct Item: Codable {
        let fileURL: URL
        let originalFilename: String
        let createdAt: Date
    }

    let items: [Item]
}
