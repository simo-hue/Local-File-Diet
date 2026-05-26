import SwiftUI

struct AppEnvironment: @unchecked Sendable {
    let temporaryFileStore: TemporaryFileStore
    let fileImportService: FileImportService
    let compressionRouter: CompressionRouter
    let historyStore: HistoryStore

    static func live() -> AppEnvironment {
        let store = TemporaryFileStore()
        return AppEnvironment(
            temporaryFileStore: store,
            fileImportService: FileImportService(store: store),
            compressionRouter: CompressionRouter(store: store),
            historyStore: HistoryStore()
        )
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.live()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
