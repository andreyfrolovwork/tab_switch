import AppKit
import ScreenCaptureKit

enum ThumbnailCache {
    private static var images: [CGWindowID: NSImage] = [:]

    static func image(for id: CGWindowID) -> NSImage? {
        images[id]
    }

    static func store(_ id: CGWindowID, _ image: NSImage) {
        images[id] = image
    }
}

enum Thumbnails {
    struct Batch {
        var images: [CGWindowID: CGImage] = [:]
        var error: String?
    }

    static func capture(_ windowIDs: [CGWindowID]) async -> Batch {
        guard CGPreflightScreenCaptureAccess() else {
            return Batch(error: "no screen capture access")
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return Batch(error: String(describing: error))
        }

        let wanted = Set(windowIDs)
        let windows = content.windows.filter { wanted.contains($0.windowID) }
        var batch = Batch()
        var firstError: String?
        let size = 4
        var index = 0
        while index < windows.count {
            let end = min(index + size, windows.count)
            let slice = windows[index..<end]
            await withTaskGroup(of: (CGWindowID, CGImage)?.self) { group in
                for window in slice {
                    group.addTask {
                        do {
                            let image = try await capture(window)
                            return (window.windowID, image)
                        } catch {
                            return nil
                        }
                    }
                }
                for await item in group {
                    if let item {
                        batch.images[item.0] = item.1
                    }
                }
            }
            index = end
        }
        if batch.images.isEmpty, !windows.isEmpty {
            firstError = "capture failed"
        }
        batch.error = firstError
        if windows.count < windowIDs.count && batch.error == nil && batch.images.isEmpty {
            batch.error = "windows not shareable"
        }
        return batch
    }

    private static func capture(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let maxPixel: CGFloat = 480
        let width = max(window.frame.width, 1)
        let height = max(window.frame.height, 1)
        let scale = min(2, maxPixel / width)
        config.width = max(1, Int((width * scale).rounded()))
        config.height = max(1, Int((height * scale).rounded()))
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
