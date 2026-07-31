import SwiftUI

/// The settings controls, factored out of `FileReviewView` so the batch screen
/// shows exactly the same controls rather than a copy that drifts.

// MARK: - Target size

struct TargetSizeSection: View {
    @Binding var selection: TargetSelectionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target size")
                .font(.headline)

            Picker("Target", selection: Binding(
                get: { selection.pickerOption },
                set: { selection.select($0) }
            )) {
                ForEach(TargetPickerOption.allOptions) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("target-preset-picker")

            if selection.isCustom {
                HStack {
                    TextField("Custom size", text: Binding(
                        get: { selection.customText },
                        set: { selection.setCustomText($0) }
                    ))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("custom-target-field")

                    Picker("Unit", selection: Binding(
                        get: { selection.customUnit },
                        set: { selection.setCustomUnit($0) }
                    )) {
                        ForEach(SizeUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }

            if let message = selection.validationMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("custom-target-validation")
            }

            Text(selection.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Quality

struct QualitySection: View {
    @Binding var qualityMode: QualityMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quality")
                .font(.headline)
            Picker("Quality", selection: $qualityMode) {
                ForEach(QualityMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Output

struct OutputSection: View {
    @Binding var settings: CompressionSettings
    let kinds: [FileKind]

    private var formats: [OutputFormat] { OutputFormat.available(for: kinds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output")
                .font(.headline)
            Picker("Format", selection: $settings.outputFormat) {
                ForEach(formats) { format in
                    Text(format.title).tag(format)
                }
            }
            .pickerStyle(.menu)

            if kinds.contains(.video) {
                Picker("Resolution", selection: Binding(
                    get: { settings.videoResolutionPreset ?? .auto },
                    set: { settings.videoResolutionPreset = $0 }
                )) {
                    ForEach(VideoResolutionPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear {
            // A format left over from another file kind would be offered by a
            // picker that no longer lists it, which SwiftUI renders as blank.
            if !formats.contains(settings.outputFormat) {
                settings.outputFormat = formats.first ?? .automatic
            }
        }
    }
}

extension OutputFormat {
    /// What can be offered for a set of files. Mixed kinds only agree on
    /// "Automatic", and saying so is better than offering JPEG for a video.
    static func available(for kinds: [FileKind]) -> [OutputFormat] {
        let unique = Set(kinds)
        guard unique.count == 1, let kind = unique.first else { return [.automatic] }
        switch kind {
        case .image: return [.automatic, .jpeg, .heic, .png, .pdf]
        case .pdf: return [.automatic, .pdf]
        case .video: return [.automatic, .mp4, .mov]
        case .archive: return [.zip]
        case .unsupported: return [.automatic]
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsSection: View {
    @Binding var settings: CompressionSettings

    var body: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Remove metadata", isOn: $settings.stripMetadata)
                    .accessibilityIdentifier("advanced-remove-metadata-toggle")
                Toggle("Preserve transparency when possible", isOn: $settings.preserveTransparency)
                    .accessibilityIdentifier("advanced-preserve-transparency-toggle")
                Toggle("Prefer smaller modern format", isOn: $settings.preferHEICWhenAvailable)
                    .accessibilityIdentifier("advanced-prefer-modern-format-toggle")
                Toggle("Allow resolution downscale", isOn: $settings.allowResolutionDownscale)
                    .accessibilityIdentifier("advanced-allow-downscale-toggle")
            }
            .toggleStyle(AdvancedSwitchToggleStyle())
            .font(.subheadline)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AdvancedSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                configuration.isOn.toggle()
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                configuration.label
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                AdvancedSwitch(isOn: configuration.isOn)
                    .frame(width: 64, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct AdvancedSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.accentColor : Color(.tertiarySystemFill))

            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
                .padding(3)
        }
        .frame(width: 54, height: 32)
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(isOn ? 0 : 0.12), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Warnings and plan rows

struct WarningRow: View {
    let warning: CompressionWarning

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title)
                    .font(.caption.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .padding(10)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var icon: String {
        switch warning.severity {
        case .blocking: "xmark.octagon"
        case .caution: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }

    private var color: Color {
        switch warning.severity {
        case .blocking: .red
        case .caution: .orange
        case .info: .secondary
        }
    }
}

/// The video engine works out its resolution and codec during the estimate.
/// Showing that before compressing is the difference between "trust us" and
/// "this will come out at 1280x720, H.264".
struct VideoOutputPlanRow: View {
    let warning: CompressionWarning

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "film.stack")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(warning.title)
                    .font(.subheadline.weight(.semibold))
                Text(warning.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("video-output-plan")
    }
}

extension FileKind {
    var symbolName: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "video"
        case .archive: "archivebox"
        case .unsupported: "questionmark.document"
        }
    }
}
