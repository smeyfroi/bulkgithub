#if DEBUG
import AppKit
import ScreenCaptureKit

/// Debug-build helper for documentation screenshots: captures the key window
/// as TRUE screen pixels via ScreenCaptureKit and writes a PNG to
/// Application Support/BulkGitHub/snapshots.
///
/// Not cacheDisplay: an offline view-tree render leaves white holes where
/// the toolbar's glass materials should be — visual-effect views sample what
/// is behind the window, which doesn't exist off-screen. ScreenCaptureKit
/// needs the one-time Screen Recording permission (macOS prompts on first
/// use), and in exchange the image is exactly what the screen shows.
enum WindowSnapshotter {
    /// One fixed frame for documentation shots, so every screenshot session
    /// produces identically sized images.
    @MainActor
    static func resizeForScreenshots() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        var frame = window.frame
        frame.origin.y -= 1000 - frame.size.height
        frame.size = NSSize(width: 1480, height: 1000)
        window.setFrame(frame, display: true)
    }

    @MainActor
    static func save() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        let windowID = CGWindowID(window.windowNumber)
        let scale = window.backingScaleFactor
        let size = window.frame.size
        Task {
            guard let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let scWindow = content.windows.first(where: { $0.windowID == windowID })
            else { return }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(size.width * scale)
            configuration.height = Int(size.height * scale)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                configuration: configuration) else { return }
            write(image)
        }
    }

    private static func write(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BulkGitHub/snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try? data.write(to: directory.appendingPathComponent("snapshot-\(stamp).png"))
    }
}
#endif
