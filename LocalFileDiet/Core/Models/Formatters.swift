import Foundation

enum FileSizeFormat {
    static func string(from bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func percent(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value / 100)) ?? "\(Int(value))%"
    }
}

enum TargetSizeParser {
    static func parse(_ text: String, unit: SizeUnit) -> Int64? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(normalized), value > 0 else { return nil }
        return Int64(value * Double(unit.multiplier))
    }
}

enum SizeUnit: String, CaseIterable, Identifiable {
    case kb = "KB"
    case mb = "MB"

    var id: String { rawValue }

    var multiplier: Int64 {
        switch self {
        case .kb: 1_000
        case .mb: 1_000_000
        }
    }
}

extension URL {
    var safeDisplayName: String {
        deletingPathExtension().lastPathComponent
    }
}
