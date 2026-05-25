import AVFoundation
import PDFKit
import SwiftUI

struct FilePreviewView: View {
    let url: URL
    let kind: FileKind

    var body: some View {
        Group {
            switch kind {
            case .image:
                ImagePreview(url: url)
            case .pdf:
                PDFPreview(url: url)
            case .video:
                VideoPreview(url: url)
            case .archive:
                PlaceholderPreview(systemImage: "archivebox", title: "ZIP Archive")
            case .unsupported:
                PlaceholderPreview(systemImage: "questionmark.document", title: "Unsupported")
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct ImagePreview: View {
    let url: URL

    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding(8)
        } else {
            PlaceholderPreview(systemImage: "photo", title: "Image preview unavailable")
        }
    }
}

private struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

private struct VideoPreview: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                PlaceholderPreview(systemImage: "video", title: "Video")
            }
            Image(systemName: "play.circle.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(radius: 6)
        }
        .task(id: url) {
            thumbnail = await makeThumbnail(url: url)
        }
    }

    private func makeThumbnail(url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        do {
            let image = try await generator.image(at: .zero).image
            return UIImage(cgImage: image)
        } catch {
            return nil
        }
    }
}

private struct PlaceholderPreview: View {
    let systemImage: String
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}
