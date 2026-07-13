import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

@MainActor
final class ClipboardThumbnailProvider {
    static let maximumCacheCost = 8 * 1_024 * 1_024

    private let cache = NSCache<NSUUID, NSImage>()

    var cacheCostLimit: Int { cache.totalCostLimit }

    func isCached(_ payloadID: UUID) -> Bool {
        cache.object(forKey: payloadID as NSUUID) != nil
    }

    init() {
        cache.totalCostLimit = Self.maximumCacheCost
        cache.countLimit = 128
    }

    func thumbnail(for payload: ClipboardPayload) async -> NSImage? {
        let key = payload.id as NSUUID
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let startedAt = ContinuousClock.now
        let image: NSImage?
        let cost: Int

        if let representation = imageRepresentation(in: payload),
           let cgImage = await Task.detached(priority: .utility, operation: {
               Self.makeImageThumbnail(from: representation.data)
           }).value {
            guard !Task.isCancelled else { return nil }
            image = NSImage(cgImage: cgImage, size: .zero)
            cost = cgImage.bytesPerRow * cgImage.height
        } else if let fileURL = firstFileURL(in: payload) {
            let result = await makeFileThumbnail(for: fileURL)
            guard !Task.isCancelled else { return nil }
            image = result.image
            cost = result.cost
        } else {
            image = nil
            cost = 0
        }

        guard let image else { return nil }
        cache.setObject(image, forKey: key, cost: cost)
        let elapsed = startedAt.duration(to: .now)
        Telemetry.interface.debug(
            "HUD thumbnail generated duration_ms=\(elapsed.milliseconds, privacy: .public) item_cost=\(cost, privacy: .public) cache_limit=\(self.cache.totalCostLimit, privacy: .public)"
        )
        return image
    }

    private func imageRepresentation(
        in payload: ClipboardPayload
    ) -> PasteboardRepresentation? {
        payload.items.lazy
            .flatMap(\.representations)
            .first { representation in
                UTType(representation.typeIdentifier)?.conforms(to: .image) == true
            }
    }

    private func firstFileURL(in payload: ClipboardPayload) -> URL? {
        for representation in payload.items.lazy.flatMap(\.representations) {
            guard representation.typeIdentifier == UTType.fileURL.identifier,
                  let value = String(data: representation.data, encoding: .utf8),
                  let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  url.isFileURL else {
                continue
            }
            return url
        }
        return nil
    }

    private func makeFileThumbnail(for url: URL) async -> (image: NSImage, cost: Int) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 72, height: 72),
            scale: scale,
            representationTypes: [.thumbnail, .icon]
        )
        if let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) {
            let image = representation.nsImage
            let pixelsWide = max(1, Int(image.size.width * scale))
            let pixelsHigh = max(1, Int(image.size.height * scale))
            return (image, pixelsWide * pixelsHigh * 4)
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return (icon, 72 * 72 * 4)
    }

    nonisolated private static func makeImageThumbnail(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 144,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        )
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
