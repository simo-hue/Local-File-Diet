import Foundation
import UniformTypeIdentifiers

struct FileTypeDetection: Sendable, Hashable {
    let type: UTType?
    let kind: FileKind
}

struct FileTypeDetector {
    func detect(url: URL) -> FileTypeDetection {
        if let magic = detectMagicBytes(url: url) {
            return magic
        }

        let extensionType = UTType(filenameExtension: url.pathExtension.lowercased())
        guard let type = extensionType else {
            return FileTypeDetection(type: nil, kind: .unsupported)
        }
        return FileTypeDetection(type: type, kind: kind(for: type))
    }

    func kind(for type: UTType) -> FileKind {
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .pdf) {
            return .pdf
        }
        if type.conforms(to: .movie) || type.conforms(to: .mpeg4Movie) || type.identifier == "com.apple.quicktime-movie" {
            return .video
        }
        if type.identifier == "public.zip-archive" || type.identifier == "com.pkware.zip-archive" {
            return .archive
        }
        return .unsupported
    }

    private func detectMagicBytes(url: URL) -> FileTypeDetection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16)) ?? Data()
        guard data.count >= 4 else { return nil }

        let bytes = [UInt8](data)
        if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) {
            return FileTypeDetection(type: .pdf, kind: .pdf)
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return FileTypeDetection(type: .jpeg, kind: .image)
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return FileTypeDetection(type: .png, kind: .image)
        }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return FileTypeDetection(type: .tiff, kind: .image)
        }
        if data.count >= 12,
           let brand = String(data: data[8..<12], encoding: .ascii),
           ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand) {
            return FileTypeDetection(type: UTType.heic, kind: .image)
        }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06]) {
            return FileTypeDetection(type: UTType(filenameExtension: "zip"), kind: .archive)
        }
        if data.count >= 12,
           let box = String(data: data[4..<8], encoding: .ascii),
           box == "ftyp" {
            return FileTypeDetection(type: UTType(filenameExtension: url.pathExtension), kind: .video)
        }
        return nil
    }
}

