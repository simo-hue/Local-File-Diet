import Foundation
import Photos
import UIKit

enum PhotoLibrarySaver {
    static func save(url: URL, kind: FileKind) async throws {
        guard kind == .image || kind == .video else {
            throw AppError.unsupportedFileType
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw AppError.exportFailed
        }

        try await PHPhotoLibrary.shared().performChanges {
            if kind == .image {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        }
    }
}
