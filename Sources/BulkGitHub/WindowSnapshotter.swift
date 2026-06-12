#if DEBUG
import AppKit

/// Debug-build helper for documentation screenshots: renders the key window
/// (its own view tree — no screen-recording permission needed) to a PNG in
/// Application Support/BulkGitHub/snapshots. Triggered from the Debug menu.
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
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
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
