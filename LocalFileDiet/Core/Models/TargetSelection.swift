import Foundation

/// Everything the target-size picker can show, in the order it shows it.
///
/// The presets are not the whole story: a user can type an exact number, and a
/// user can say "no limit at all", which the engines have always supported
/// (`targetSizeBytes == nil`) but the UI never offered.
enum TargetPickerOption: Hashable, Identifiable, Sendable {
    case preset(TargetSizePreset)
    case custom
    case noLimit

    static let allOptions: [TargetPickerOption] =
        TargetSizePreset.allCases.map(TargetPickerOption.preset) + [.custom, .noLimit]

    var id: String {
        switch self {
        case .preset(let preset): "preset-\(preset.rawValue)"
        case .custom: "custom"
        case .noLimit: "no-limit"
        }
    }

    var title: String {
        switch self {
        case .preset(let preset): preset.title
        case .custom: "Custom size"
        case .noLimit: "No limit"
        }
    }
}

/// The single source of truth behind the target-size controls.
///
/// Before this type there were two independent pieces of state: a hardcoded
/// `selectedPreset` and `settings.targetSizeBytes` read from the user's saved
/// default. They disagreed the moment the saved default was anything other than
/// "Under 10 MB", so the picker displayed one number while the engines received
/// another. Both the picker selection and the byte target are now derived from
/// one `mode`, so they cannot drift apart.
///
/// Deliberately a plain value type with no SwiftUI in sight: this is the part of
/// the screen that has actual rules, so it is the part that has to be testable.
struct TargetSelectionState: Equatable, Sendable {
    enum Mode: Equatable, Hashable, Sendable {
        case preset(TargetSizePreset)
        case custom(bytes: Int64)
        case noLimit
    }

    /// A custom target below this is not a request any format can honour; it is
    /// a typo. Rejecting it here keeps the engines from chasing an impossible
    /// number and keeps the user from wondering why nothing worked.
    static let minimumCustomBytes: Int64 = 10_000

    private(set) var mode: Mode
    private(set) var customText: String
    private(set) var customUnit: SizeUnit
    /// Set when input was rejected, so the screen can say why instead of
    /// silently ignoring what was typed.
    private(set) var validationMessage: String?
    /// Where clearing the custom field goes back to. Never a custom value, so
    /// an empty field can never leave a stale number in effect.
    private var fallbackMode: Mode

    // MARK: - Creation

    /// Starts from the user's saved default preset, so the picker opens showing
    /// exactly what Settings promised it would.
    static func fromDefaults(_ defaults: UserDefaults = .standard) -> TargetSelectionState {
        let preset = defaults.string(forKey: AppDefaults.defaultTargetPresetKey)
            .flatMap(TargetSizePreset.init(rawValue:)) ?? .forms
        return TargetSelectionState(mode: .preset(preset))
    }

    /// Rebuilds the selection from a byte target — used when arriving with
    /// settings from somewhere else, such as "Try Smaller" on the result screen.
    init(targetBytes: Int64?) {
        guard let targetBytes else {
            self.init(mode: .noLimit)
            return
        }
        if let preset = TargetSizePreset.allCases.first(where: { $0.bytes == targetBytes }) {
            self.init(mode: .preset(preset))
        } else {
            self.init(mode: .custom(bytes: targetBytes))
        }
    }

    init(mode: Mode) {
        self.mode = mode
        self.fallbackMode = Self.nonCustomFallback(for: mode)
        self.validationMessage = nil
        switch mode {
        case .custom(let bytes):
            let seed = Self.textAndUnit(for: bytes)
            self.customText = seed.text
            self.customUnit = seed.unit
        case .preset, .noLimit:
            self.customText = ""
            self.customUnit = .mb
        }
    }

    // MARK: - Derived values

    /// What the engines are actually asked for. `nil` means "no limit", which
    /// every engine already handles.
    var targetSizeBytes: Int64? {
        switch mode {
        case .preset(let preset): preset.bytes
        case .custom(let bytes): bytes
        case .noLimit: nil
        }
    }

    /// What the picker shows. Derived, never stored, so it cannot disagree with
    /// `targetSizeBytes`.
    var pickerOption: TargetPickerOption {
        switch mode {
        case .preset(let preset): .preset(preset)
        case .custom: .custom
        case .noLimit: .noLimit
        }
    }

    var isCustom: Bool {
        if case .custom = mode { return true }
        return false
    }

    var summary: String {
        switch mode {
        case .noLimit: "No size limit — just make it smaller"
        case .preset(let preset): "Target: \(FileSizeFormat.string(from: preset.bytes)) (\(preset.title))"
        case .custom(let bytes): "Target: \(FileSizeFormat.string(from: bytes))"
        }
    }

    // MARK: - Mutation

    mutating func select(_ option: TargetPickerOption) {
        validationMessage = nil
        switch option {
        case .preset(let preset):
            mode = .preset(preset)
            fallbackMode = mode
        case .noLimit:
            mode = .noLimit
            fallbackMode = mode
        case .custom:
            // Seed the field from whatever is in effect right now, so switching
            // to Custom never blanks the target out from under the user.
            let seedBytes = targetSizeBytes ?? TargetSizePreset.forms.bytes
            fallbackMode = Self.nonCustomFallback(for: mode)
            let seed = Self.textAndUnit(for: seedBytes)
            customText = seed.text
            customUnit = seed.unit
            mode = .custom(bytes: seedBytes)
        }
    }

    mutating func setCustomText(_ text: String) {
        customText = text
        apply(text: text, unit: customUnit)
    }

    mutating func setCustomUnit(_ unit: SizeUnit) {
        customUnit = unit
        apply(text: customText, unit: unit)
    }

    private mutating func apply(text: String, unit: SizeUnit) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty field must not leave the last number quietly in force.
        if trimmed.isEmpty {
            if isCustom {
                mode = fallbackMode
                validationMessage = "Custom size cleared. Using \(Self.title(for: fallbackMode))."
            } else {
                validationMessage = nil
            }
            return
        }

        guard let parsed = TargetSizeParser.parse(trimmed, unit: unit) else {
            // Keep whatever valid target is already in effect: a half-typed
            // number must never silently retarget the compression.
            validationMessage = "Enter a size like 2 or 1.5."
            return
        }
        guard parsed >= Self.minimumCustomBytes else {
            validationMessage = "Use at least \(FileSizeFormat.string(from: Self.minimumCustomBytes))."
            return
        }
        if !isCustom {
            fallbackMode = Self.nonCustomFallback(for: mode)
        }
        mode = .custom(bytes: parsed)
        validationMessage = nil
    }

    // MARK: - Helpers

    private static func nonCustomFallback(for mode: Mode) -> Mode {
        switch mode {
        case .preset, .noLimit: mode
        case .custom: .noLimit
        }
    }

    private static func title(for mode: Mode) -> String {
        switch mode {
        case .preset(let preset): preset.title
        case .noLimit: "No limit"
        case .custom(let bytes): FileSizeFormat.string(from: bytes)
        }
    }

    /// Shows a byte count back to the user in the unit they would have typed.
    static func textAndUnit(for bytes: Int64) -> (text: String, unit: SizeUnit) {
        let unit: SizeUnit = bytes >= SizeUnit.mb.multiplier ? .mb : .kb
        let value = Double(bytes) / Double(unit.multiplier)
        if value == value.rounded() {
            return (String(Int(value)), unit)
        }
        return (String(format: "%.2f", value), unit)
    }
}
