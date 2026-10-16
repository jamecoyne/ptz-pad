import AppKit
import CoreImage

// Ported from segcam (Sources/SwarmCanvas.swift): its windowed mode drawn into the frame,
// minus the title bars. Every new segment becomes a window frozen on the picture it was
// found in; windows pile up newest on top and the oldest is recycled once the pile is
// full. Detection numbers each pass afresh, so every pass adds windows — a trail.

/// Only touched from the render thread (under `VideoController.renderLock`).
final class WindowTrail {
    private struct Tile {
        let rect: CGRect            // the picture, in frame pixels, bottom-left origin
        let image: CGImage?
    }

    private var tiles: [Tile] = []       // oldest first

    var count: Int { tiles.count }

    func clear() { tiles.removeAll() }

    /// Freezes each segment's patch of `image` into a new window.
    func add(_ segments: [Segment], from image: CIImage, extent: CGRect,
             context: CIContext, colorSpace: CGColorSpace, limit: Int) {
        let W = extent.width, H = extent.height
        for segment in segments {
            let r = segment.rect
            let rect = CGRect(x: r.x * W, y: (1 - r.y - r.h) * H, width: r.w * W, height: r.h * H)
                .integral.intersection(extent)
            guard rect.width >= 2, rect.height >= 2 else { continue }
            tiles.append(Tile(rect: rect, image: context.createCGImage(image, from: rect, format: .BGRA8,
                                                                         colorSpace: colorSpace)))
        }
        if tiles.count > limit { tiles.removeFirst(tiles.count - limit) }
    }

    /// Oldest to newest; a full redraw, so recycling a window reveals what was under it.
    func draw(in ctx: CGContext) {
        ctx.interpolationQuality = .low
        for tile in tiles {
            if let image = tile.image { ctx.draw(image, in: tile.rect) }
        }
    }
}
