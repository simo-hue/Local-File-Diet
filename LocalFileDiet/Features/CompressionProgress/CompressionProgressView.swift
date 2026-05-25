import SwiftUI

struct CompressionProgressView: View {
    let progress: CompressionProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            ProgressView(value: progress.fractionCompleted ?? 0)
                .progressViewStyle(.linear)
            VStack(spacing: 6) {
                Text(progress.message)
                    .font(.headline)
                Text(progress.phase.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(role: .cancel) {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding()
    }
}

