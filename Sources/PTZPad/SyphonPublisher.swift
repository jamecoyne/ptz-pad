import CBridge
import CoreVideo
import Foundation
import IOSurface

/// Publishes processed frames as a Syphon feed for Resolume, TouchDesigner, OBS…
///
/// The Syphon build that TouchDesigner/OBS ship has no Metal server, only
/// `SyphonServerBase`'s subclassing category, which hands out a BGRA8 IOSurface to fill
/// on the CPU (same approach as segcam's SyphonOutput). Each frame is copied into it in
/// one go — about a millisecond for 1080p — and published.
final class SyphonPublisher {
    /// Off, row 0 of the surface is the top of the picture. Resolume assumes OpenGL's
    /// bottom-up rows and shows that upside down, so VideoController turns this on by default.
    var flipped = false

    private var server: SyphonServerBase?
    private let lock = NSLock()

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return server != nil }
    var hasClients: Bool { lock.lock(); defer { lock.unlock() }; return server?.hasClients ?? false }

    func start(name: String) {
        lock.lock(); defer { lock.unlock() }
        guard server == nil else { return }
        server = SyphonServerBase(name: name, options: nil)
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        server?.stop()
        server = nil
    }

    /// Copies a BGRA buffer into the feed. The buffer's base address must already be
    /// locked. Nothing is copied while no client is connected.
    func publish(base: UnsafeRawPointer, width: Int, height: Int, stride: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let server, server.hasClients,
              let surface = server.copySurface(forWidth: width, height: height, options: nil)?
                .takeRetainedValue()
        else { return }

        IOSurfaceLock(surface, [], nil)
        if let dest = IOSurfaceGetBaseAddress(surface) as UnsafeMutableRawPointer? {
            let destStride = IOSurfaceGetBytesPerRow(surface)
            let count = min(stride, destStride, width * 4)
            if !flipped && destStride == stride {
                memcpy(dest, base, stride * height)
            } else {
                for row in 0..<height {
                    memcpy(dest + (flipped ? height - 1 - row : row) * destStride, base + row * stride, count)
                }
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        server.publish()
    }
}
