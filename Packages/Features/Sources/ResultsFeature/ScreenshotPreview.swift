import ImageIO
import SwiftUI

struct ScreenshotPreview: View {
    let url: URL
    let maxPixelSize: Int

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(StillsetStyle.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
        .task(id: url) {
            let sourceURL = url
            let pixelSize = maxPixelSize
            let loadedImage: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixelSize
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            guard let loadedImage else { return }
            image = loadedImage
        }
    }
}
