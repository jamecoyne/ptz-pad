import CoreGraphics
import Foundation
import ImageIO

/// The saved face crops, decoded and kept in memory so the render thread can paste a
/// random one over each detected face. Rescans the folder so new saves join in.
final class FaceLibrary {
    /// Most recent crops kept; they're small (~100 px), so this is a few MB.
    private let limit = 500
    private let queue = DispatchQueue(label: "ptzpad.facelibrary", qos: .utility)
    private let images = Atomic<[CGImage]>([])
    private var cache: [URL: CGImage] = [:]          // only touched on `queue`
    private let scanning = Atomic(false)

    var count: Int { images.value.count }

    func random() -> CGImage? { images.value.randomElement() }

    /// Picks up crops saved (or deleted) since the last scan, off the main thread.
    func reload(from root: URL) {
        guard !scanning.value else { return }
        scanning.value = true
        queue.async { [self] in
            defer { scanning.value = false }
            let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension.lowercased() == "jpg" }
                // Names are the date folder then the time, so the path sorts by age.
                .sorted { $0.path < $1.path }
                .suffix(limit)
            var next: [URL: CGImage] = [:]
            for url in files {
                if let image = cache[url] ?? load(url) { next[url] = image }
            }
            cache = next
            images.value = Array(next.values)
        }
    }

    private func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
