import Foundation

enum AppError: LocalizedError, Equatable {
    case unsupportedFileType
    case importFailed
    case fileUnavailable
    case protectedPDF
    case corruptFile
    case notEnoughStorage
    case targetUnreachable(String)
    case cancelled
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            "This file type is not supported yet."
        case .importFailed:
            "Could not import this file."
        case .fileUnavailable:
            "The file is not available locally."
        case .protectedPDF:
            "This PDF is password-protected and cannot be compressed."
        case .corruptFile:
            "This file appears to be damaged or unreadable."
        case .notEnoughStorage:
            "There is not enough free space to write the compressed file."
        case .targetUnreachable(let detail):
            "Could not reach the target size. \(detail)"
        case .cancelled:
            "Compression was cancelled."
        case .exportFailed:
            "Could not export the compressed file."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unsupportedFileType:
            "Try a PDF, image, video, or ZIP file."
        case .importFailed, .fileUnavailable:
            "Download the file locally first, then try again."
        case .protectedPDF:
            "Open the PDF in its original app and remove the password, then import it again."
        case .corruptFile:
            "Try opening the original file to confirm it works."
        case .notEnoughStorage:
            "Free up space and try again."
        case .targetUnreachable:
            "Try a larger target or choose Smallest file."
        case .cancelled:
            nil
        case .exportFailed:
            "Try sharing the file instead, or compress it again."
        }
    }
}
