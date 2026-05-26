import SwiftUI

@main
struct LocalFileDietApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(\.appEnvironment, environment)
                .environment(environment.historyStore)
                .task {
                    await environment.temporaryFileStore.cleanupOlderThan24Hours()
                }
        }
    }
}
