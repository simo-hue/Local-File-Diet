import SwiftUI

struct AppRootView: View {
    @Environment(\.appEnvironment) private var environment
    @State private var path: [AppRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView { input in
                path.append(.review(input, nil))
            } onImportedBatch: { inputs in
                path.append(.batch(inputs))
            }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .review(let input, let startingSettings):
                    FileReviewView(input: input, startingSettings: startingSettings) { result, settings in
                        path.append(.result(input, result, settings))
                    }
                case .result(let input, let result, let settings):
                    ResultView(input: input, result: result, settings: settings) { nextInput, nextSettings in
                        // The retry buttons hand back real settings, so the next
                        // review screen starts from them instead of re-reading
                        // the saved defaults and losing the point of the button.
                        path.append(.review(nextInput, nextSettings))
                    } onStartNewImport: {
                        path.removeAll()
                    }
                case .batch(let inputs):
                    BatchReviewView(inputs: inputs) { outcome in
                        path.append(.batchResult(outcome))
                    }
                case .batchResult(let outcome):
                    BatchResultView(outcome: outcome) {
                        path.removeAll()
                    }
                }
            }
        }
        .onOpenURL { url in
            guard url.scheme == AppGroup.urlScheme else { return }
            Task {
                let inputs = (try? await environment.fileImportService.importSharedFilesIfAvailable()) ?? []
                guard !inputs.isEmpty else { return }
                // A file arriving from the share sheet is a new job. Appending it
                // to whatever stack was open buried it under the previous file's
                // result screen.
                path.removeAll()
                if inputs.count == 1, let input = inputs.first {
                    path.append(.review(input, nil))
                } else {
                    path.append(.batch(inputs))
                }
            }
        }
    }
}

enum AppRoute: Hashable {
    /// The optional settings are where a "Try Smaller" retry carries its
    /// intent; `nil` means "start from the user's defaults".
    case review(CompressionInput, CompressionSettings?)
    case result(CompressionInput, CompressionResult, CompressionSettings)
    case batch([CompressionInput])
    case batchResult(BatchOutcome)
}
