import Foundation
import OSLog

enum AppLogger {
    static let compression = Logger(subsystem: "com.simohue.localfilediet", category: "compression")
    static let importFlow = Logger(subsystem: "com.simohue.localfilediet", category: "import")

    static func sizeBucket(for bytes: Int64) -> String {
        switch bytes {
        case 0..<2_000_000: "0-2MB"
        case 2_000_000..<10_000_000: "2-10MB"
        case 10_000_000..<50_000_000: "10-50MB"
        case 50_000_000..<200_000_000: "50-200MB"
        default: "200MB+"
        }
    }
}
