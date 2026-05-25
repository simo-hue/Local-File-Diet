import SwiftUI

struct AppRootView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView { input in
                path.append(.review(input))
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .review(let input):
                    FileReviewView(input: input) { result, settings in
                        path.append(.result(input, result, settings))
                    }
                case .result(let input, let result, let settings):
                    ResultView(input: input, result: result, settings: settings) { nextInput in
                        path.append(.review(nextInput))
                    }
                }
            }
        }
        .onOpenURL { url in
            guard url.scheme == AppGroup.urlScheme else { return }
            Task {
                if let input = try? await environment.fileImportService.importSharedFileIfAvailable() {
                    path.append(.review(input))
                }
            }
        }
    }
}

enum AppRoute: Hashable {
    case review(CompressionInput)
    case result(CompressionInput, CompressionResult, CompressionSettings)
}
