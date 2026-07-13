import Foundation
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ClipboardThumbnailProviderTests: XCTestCase {
    func testImageThumbnailIsGeneratedAndCached() async throws {
        let provider = ClipboardThumbnailProvider()
        let payload = imagePayload(data: try XCTUnwrap(testPNGData))

        let first = await provider.thumbnail(for: payload)
        let second = await provider.thumbnail(for: payload)

        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)
        XCTAssertTrue(provider.isCached(payload.id))
        XCTAssertEqual(
            provider.cacheCostLimit,
            ClipboardThumbnailProvider.maximumCacheCost
        )
    }

    func testMalformedImageFailsWithoutCaching() async {
        let provider = ClipboardThumbnailProvider()
        let payload = imagePayload(data: Data("not an image".utf8))

        let image = await provider.thumbnail(for: payload)

        XCTAssertNil(image)
        XCTAssertFalse(provider.isCached(payload.id))
    }

    func testTextDoesNotStartImageOrFileThumbnailWork() async {
        let provider = ClipboardThumbnailProvider()
        let data = Data("hello".utf8)
        let payload = ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: UTType.utf8PlainText.identifier,
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .text,
            preview: "hello",
            byteCount: data.count
        )

        let thumbnail = await provider.thumbnail(for: payload)
        XCTAssertNil(thumbnail)
        XCTAssertFalse(provider.isCached(payload.id))
    }

    func testUnavailableFileUsesNativeIconFallback() async {
        let provider = ClipboardThumbnailProvider()
        let url = URL(fileURLWithPath: "/path/that/does/not/exist.txt")
        let data = Data(url.absoluteString.utf8)
        let payload = ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: UTType.fileURL.identifier,
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .files,
            preview: "File",
            byteCount: data.count
        )

        let thumbnail = await provider.thumbnail(for: payload)
        XCTAssertNotNil(thumbnail)
        XCTAssertTrue(provider.isCached(payload.id))
    }

    func testCancelledRequestDoesNotPopulateCache() async throws {
        let provider = ClipboardThumbnailProvider()
        let payload = imagePayload(data: try XCTUnwrap(testPNGData))
        let task = Task { await provider.thumbnail(for: payload) }
        task.cancel()

        _ = await task.value

        XCTAssertFalse(provider.isCached(payload.id))
    }

    private func imagePayload(data: Data) -> ClipboardPayload {
        ClipboardPayload(
            items: [
                PasteboardItemPayload(
                    representations: [
                        PasteboardRepresentation(
                            typeIdentifier: UTType.png.identifier,
                            data: data
                        ),
                    ]
                ),
            ],
            kind: .image,
            preview: "Image",
            byteCount: data.count
        )
    }

    private var testPNGData: Data? {
        Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )
    }
}
