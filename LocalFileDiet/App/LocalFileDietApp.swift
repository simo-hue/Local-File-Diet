import SwiftUI

@main
struct LocalFileDietApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(\.appEnvironment, environment)
                .environment(environment.historyStore)
                .environment(environment.purchaseService)
                .task {
                    await environment.temporaryFileStore.cleanupOlderThan24Hours()
                    await environment.purchaseService.loadProducts()
                }
        }
    }
}

