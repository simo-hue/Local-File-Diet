import ObjectiveC
import Social
import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let appGroupIdentifier = "group.com.simohue.localfilediet"
    /// Must stay equal to the `NSExtensionActivationSupports*WithMaxCount` values
    /// in Info.plist. iOS hides the extension from the share sheet entirely once
    /// a selection goes over those numbers, so a smaller bound here would drop
    /// attachments the share sheet had already accepted, and a larger one would
    /// advertise a batch size the user can never actually reach.
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
            ShareFileInbox.pruneUnreferencedFiles(appGroupIdentifier: appGroupIdentifier)
            let files = try await loadIncomingFiles()
            guard !files.isEmpty else {
                showFailure("Nothing to compress was found in what you shared.")
                return
            }
            try writeManifest(for: files)
            statusLabel.text = files.count == 1
                ? "Opening Local File Diet..."
                : "Opening Local File Diet with \(files.count) files..."
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
    private func loadIncomingFiles() async throws -> [IncomingFile] {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return []
        }

        var copied: [IncomingFile] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if copied.count >= maximumAttachments { break }
                guard provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) else { continue }
                // One unreadable attachment must not lose the others.
                if let file = try? await loadFile(from: provider) {
                    copied.append(file)
                }
            }
        }
        return copied
    }

    private func loadFile(from provider: NSItemProvider) async throws -> IncomingFile {
        let appGroupIdentifier = appGroupIdentifier
        return try await withCheckedThrowingContinuation { continuation in
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
                    let destination = try ShareFileInbox.makeIncomingURL(originalURL: url, appGroupIdentifier: appGroupIdentifier)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: url, to: destination)
                    ShareFileInbox.protect(destination)
                    // The copy is named `<UUID>-<original>` so two shares of the
                    // same photo cannot collide. The original name is carried
                    // separately, otherwise the app names its output after the
                    // UUID as well.
                    continuation.resume(returning: IncomingFile(url: destination, originalFilename: url.lastPathComponent))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeManifest(for files: [IncomingFile]) throws {
        let incoming = try ShareFileInbox.directory(appGroupIdentifier: appGroupIdentifier)
        let manifest = SharedManifest(items: files.map {
            SharedManifest.Item(fileURL: $0.url, originalFilename: $0.originalFilename, createdAt: Date())
        })
        let manifestURL = incoming.appendingPathComponent(ShareFileInbox.manifestFilename)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
        ShareFileInbox.protect(manifestURL)
        // There is only ever one manifest, so the one just written abandons
        // whatever share was still waiting; its copies are dead weight now.
        // Sweeping after the write rather than before means a crash in between
        // leaves a manifest that still matches its files, and the leftovers get
        // caught by the next launch's prune.
        ShareFileInbox.removeContents(
            of: incoming,
            keeping: Set(files.map { $0.url.lastPathComponent }).union([ShareFileInbox.manifestFilename])
        )
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

private struct IncomingFile {
    /// Where the copy landed inside the app group container.
    let url: URL
    /// The name the user sees, without the uniquing UUID prefix.
    let originalFilename: String
}

private enum ShareFileInbox {
    static let manifestFilename = "share-manifest.json"

    static func directory(appGroupIdentifier: String) throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let incoming = container.appendingPathComponent("Incoming", isDirectory: true)
        if !FileManager.default.fileExists(atPath: incoming.path) {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        }
        var mutable = incoming
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        return incoming
    }

    static func makeIncomingURL(originalURL: URL, appGroupIdentifier: String) throws -> URL {
        let incoming = try directory(appGroupIdentifier: appGroupIdentifier)
        let filename = originalURL.lastPathComponent.isEmpty ? "shared-file" : originalURL.lastPathComponent
        return incoming.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }

    /// A share is a full copy of the user's file sitting in the app group
    /// container, so it gets the same treatment `TemporaryFileStore` gives the
    /// app's own working copies: kept out of device backups, and unreadable
    /// until the phone has been unlocked once since boot.
    static func protect(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    /// A share waiting to be collected is worth keeping for a day, the same
    /// window `TemporaryFileStore` gives the app's own working copies. Past
    /// that it is a share the user backed out of, and the copies are dead
    /// weight in the app group container.
    static let pendingShareLifetime: TimeInterval = 24 * 60 * 60

    /// Nothing else cleans this directory. The app deletes only the files the
    /// manifest names, so a share the user backs out of - or one the app is
    /// never opened to collect - used to sit in the app group container for
    /// good. Whatever a live manifest still points at is kept; the rest goes,
    /// including a manifest too old to be worth waiting for and one too
    /// damaged to read, since the app can do nothing with either.
    ///
    /// Age comes from the manifest's own `createdAt`, never from the files'
    /// timestamps. Reading those would put this extension into Apple's
    /// required-reason file timestamp category, and the extension ships
    /// without a privacy manifest of its own.
    static func pruneUnreferencedFiles(appGroupIdentifier: String, now: Date = Date()) {
        guard let incoming = try? directory(appGroupIdentifier: appGroupIdentifier) else { return }
        var keep: Set<String> = []
        if let manifest = pendingManifest(in: incoming), !isExpired(manifest, now: now) {
            keep.insert(manifestFilename)
            keep.formUnion(manifest.items.map { $0.fileURL.lastPathComponent })
        }
        removeContents(of: incoming, keeping: keep)
    }

    /// An empty manifest names nothing to wait for, so it counts as expired.
    static func isExpired(_ manifest: SharedManifest, now: Date) -> Bool {
        guard let newest = manifest.items.map({ $0.createdAt }).max() else { return true }
        return now.timeIntervalSince(newest) > pendingShareLifetime
    }

    static func removeContents(of incoming: URL, keeping keep: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: incoming,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where !keep.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func pendingManifest(in incoming: URL) -> SharedManifest? {
        let url = incoming.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedManifest.self, from: data)
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
