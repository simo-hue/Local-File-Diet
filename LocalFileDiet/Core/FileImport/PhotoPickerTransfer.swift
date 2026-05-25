import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct PickedMediaFile: Transferable {
    let url: URL
    let suggestedFilename: String?

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            let filename = received.file.lastPathComponent.isEmpty ? "photo-library-file" : received.file.lastPathComponent
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("PickedMedia-\(UUID().uuidString)-\(filename)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMediaFile(url: destination, suggestedFilename: filename)
        }
    }
}

