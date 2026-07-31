import ObjectiveC
import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.com.simohue.localfilediet"
    /// A share sheet can hand over a lot of attachments; this is a sanity bound,
    /// not a product limit.
    private let maximumAttachments = 25

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let closeButton = UIButton(type: .system)
    private var hasStarted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            await handleSharedItems()
        }
    }

    // MARK: - Interface

    /// The extension used to show nothing at all and complete on appear, so a
    /// failure looked exactly like a success: the sheet vanished and no app
    /// opened. A label and a spinner are the minimum needed to tell the user
    /// what happened.
    private func buildInterface() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "Preparing your files..."
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true

        closeButton.setTitle("Close", for: .normal)
        closeButton.isHidden = true
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel, closeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])

        spinner.startAnimating()
    }

    private func showFailure(_ message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = message
        closeButton.isHidden = false
    }

    @objc private func closeTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Work

    private func handleSharedItems() async {
        do {
            let urls = try await loadIncomingFiles()
            guard !urls.isEmpty else {
                showFailure("Nothing to compress was found in what you shared.")
                return
            }
            try writeManifest(for: urls)
            statusLabel.text = urls.count == 1
                ? "Opening Local File Diet..."
                : "Opening Local File Diet with \(urls.count) files..."
            guard openContainingApp() else {
                showFailure("Could not open Local File Diet. Open the app and your shared files will be waiting.")
                return
            }
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            showFailure("Could not prepare these files. \(error.localizedDescription)")
        }
    }

    /// Takes every attachment, not just the first. The single-file `break` here
    /// is what made "share five photos into the app" quietly turn into one.
    private func loadIncomingFiles() async throws -> [URL] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }

        var copiedURLs: [URL] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if copiedURLs.count >= maximumAttachments { break }
                guard provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) else { continue }
                // One unreadable attachment must not lose the others.
                if let copied = try? await loadFile(from: provider) {
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

    /// `extensionContext.open` is documented, but on iOS it only actually opens
    /// a URL for some extension types and does nothing for a share extension, so
    /// the file was written and then nothing happened. It is still tried first;
    /// the responder walk is the fallback that does the work.
    /// - Returns: whether anything was found that could open the URL.
    private func openContainingApp() -> Bool {
        guard let url = URL(string: "localfilediet://share") else { return false }
        extensionContext?.open(url, completionHandler: nil)
        return openViaResponderChain(url)
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                // The method we want is `open(_:options:completionHandler:)`, but
                // it is unavailable to app-extension targets at compile time, so
                // it is dispatched by selector on the instance we just found.
                let modern = NSSelectorFromString("openURL:options:completionHandler:")
                if application.responds(to: modern),
                   let implementation = class_getMethodImplementation(type(of: application), modern) {
                    typealias OpenURLFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                    let open = unsafeBitCast(implementation, to: OpenURLFunction.self)
                    open(application, modern, url as NSURL, NSDictionary(), nil)
                    return true
                }
                let legacy = NSSelectorFromString("openURL:")
                if application.responds(to: legacy) {
                    _ = application.perform(legacy, with: url)
                    return true
                }
            }
            responder = current.next
        }
        return false
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
