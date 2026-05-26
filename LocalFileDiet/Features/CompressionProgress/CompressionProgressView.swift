import SwiftUI

enum ProgressPresentation {
    static func smoothed(current: CompressionProgress?, next: CompressionProgress) -> CompressionProgress {
        let nextFraction = displayFraction(for: next)
        let currentFraction = current.map(displayFraction(for:))
        let fraction = max(currentFraction ?? 0, nextFraction)
        return CompressionProgress(
            phase: next.phase,
            fractionCompleted: next.phase == .completed ? 1 : fraction,
            message: next.message
        )
    }

    static func displayFraction(for progress: CompressionProgress) -> Double {
        let fallback = fallbackFraction(for: progress.phase)
        return min(max(progress.fractionCompleted ?? fallback, 0), 1)
    }

    static func stepIndex(for phase: CompressionPhase) -> Int {
        switch phase {
        case .preparing:
            0
        case .analyzing:
            1
        case .downsampling, .encoding, .optimizing:
            2
        case .writing, .verifying:
            3
        case .completed:
            4
        }
    }

    private static func fallbackFraction(for phase: CompressionPhase) -> Double {
        switch phase {
        case .preparing:
            0.06
        case .analyzing:
            0.18
        case .downsampling:
            0.34
        case .encoding:
            0.54
        case .optimizing:
            0.68
        case .writing:
            0.84
        case .verifying:
            0.94
        case .completed:
            1
        }
    }
}

struct CompressionProgressView: View {
    let progress: CompressionProgress
    let onCancel: () -> Void
    @State private var isAnimating = false

    private var fraction: Double {
        ProgressPresentation.displayFraction(for: progress)
    }

    var body: some View {
        VStack(spacing: 22) {
            HeroProgressRing(
                fraction: fraction,
                phase: progress.phase,
                isAnimating: isAnimating
            )

            VStack(spacing: 6) {
                Text("Compressing locally")
                    .font(.title3.weight(.semibold))
                Text(progress.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                EnergyProgressBar(fraction: fraction, isAnimating: isAnimating)
                    .frame(height: 12)
                PhaseTimeline(phase: progress.phase)
            }

            Label("Your original file stays untouched.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .cancel) {
                onCancel()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 28, y: 12)
        .padding()
        .task {
            guard !isAnimating else { return }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
                isAnimating = true
            }
        }
    }
}

private struct HeroProgressRing: View {
    let fraction: Double
    let phase: CompressionPhase
    let isAnimating: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.16), lineWidth: 12)

            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(
                        colors: [Color.accentColor, .cyan, .blue, Color.accentColor],
                        center: .center,
                        angle: .degrees(isAnimating ? 360 : 0)
                    ),
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.55, dampingFraction: 0.82), value: fraction)

            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 118, height: 118)

            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)

                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()

                Text(phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 174, height: 174)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Compression progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }

    private var icon: String {
        switch phase {
        case .preparing:
            "doc.badge.gearshape"
        case .analyzing:
            "waveform.path.ecg"
        case .downsampling:
            "arrow.down.right.and.arrow.up.left"
        case .encoding:
            "wand.and.sparkles"
        case .optimizing:
            "slider.horizontal.3"
        case .writing:
            "square.and.arrow.down"
        case .verifying:
            "checkmark.shield"
        case .completed:
            "checkmark.seal.fill"
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .preparing:
            "Preparing"
        case .analyzing:
            "Analyzing"
        case .downsampling:
            "Resizing"
        case .encoding:
            "Encoding"
        case .optimizing:
            "Optimizing"
        case .writing:
            "Writing"
        case .verifying:
            "Verifying"
        case .completed:
            "Ready"
        }
    }
}

private struct EnergyProgressBar: View {
    let fraction: Double
    let isAnimating: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.14))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor, .cyan, .blue],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(geometry.size.width * fraction, 12))
                    .animation(.spring(response: 0.55, dampingFraction: 0.82), value: fraction)
            }
            .overlay {
                LinearGradient(
                    colors: [.clear, .white.opacity(0.72), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geometry.size.width * 0.38)
                .offset(x: isAnimating ? geometry.size.width : -geometry.size.width * 0.5)
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: isAnimating)
                .blendMode(.screen)
            }
            .clipShape(Capsule())
        }
    }
}

private struct PhaseTimeline: View {
    let phase: CompressionPhase
    private let steps = ["Prep", "Analyze", "Encode", "Verify", "Done"]

    var body: some View {
        let currentIndex = ProgressPresentation.stepIndex(for: phase)

        HStack(spacing: 6) {
            ForEach(steps.indices, id: \.self) { index in
                VStack(spacing: 6) {
                    Circle()
                        .fill(index <= currentIndex ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: index == currentIndex ? 10 : 7, height: index == currentIndex ? 10 : 7)
                        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: currentIndex)

                    Text(steps[index])
                        .font(.caption2.weight(index == currentIndex ? .semibold : .regular))
                        .foregroundStyle(index <= currentIndex ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}
