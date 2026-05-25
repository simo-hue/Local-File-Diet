import Foundation

enum CompressionMath {
    static func reductionPercent(original: Int64, compressed: Int64) -> Double {
        guard original > 0 else { return 0 }
        return max(0, (1 - (Double(compressed) / Double(original))) * 100)
    }

    static func targetReached(size: Int64, target: Int64?) -> Bool {
        guard let target else { return size > 0 }
        return size <= target
    }

    static func estimatedReduction(original: Int64, estimated: Int64?) -> Double? {
        guard let estimated else { return nil }
        return reductionPercent(original: original, compressed: estimated)
    }
}

enum OutputFilename {
    static func make(original: String, outputExtension: String) -> String {
        let base = URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent
        let clean = base.isEmpty ? "compressed-file" : base
        return "\(clean)-compressed.\(outputExtension)"
    }
}

extension FileManager {
    func fileSize(at url: URL) -> Int64 {
        let attributes = try? attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

extension Array where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
