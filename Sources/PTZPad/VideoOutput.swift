import CBridge
import Foundation

/// Where processed frames go. VideoController keeps one of each and feeds only the
/// selected one; the other is stopped.
protocol VideoOutput: AnyObject {
    var isRunning: Bool { get }
    /// Whether anything is receiving the feed. Outputs skip work while this is false.
    var hasClients: Bool { get }
    func start(name: String)
    func stop()
    /// Called on the render thread with a locked BGRA buffer, row 0 at the top.
    func publish(base: UnsafeRawPointer, width: Int, height: Int, stride: Int)
}

enum OutputKind: String, CaseIterable, Identifiable {
    case syphon, ndi
    var id: String { rawValue }
    var label: String {
        switch self {
        case .syphon: return "Syphon"
        case .ndi: return "NDI"
        }
    }
}

extension SyphonPublisher: VideoOutput {}

/// Sends processed frames out as an NDI source, through the same run-time-loaded libndi
/// that receives the camera. Frames go as BGRX, top row first, which is what NDI expects,
/// so there is no flip option.
final class NDIPublisher: VideoOutput {
    private let lib = NDILibrary.shared
    private var instance: NDIlib_send_instance_t?
    private let lock = NSLock()
    private var lastSend: CFAbsoluteTime = 0
    private var frameInterval: Double = 1.0 / 30

    /// Why the sender couldn't start, if it couldn't.
    private(set) var error: String?
    /// The full name receivers see, e.g. "MY-MAC (Camera)". Set while running.
    private(set) var sourceName: String?

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return instance != nil }

    var hasClients: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let instance, let count = lib.sendConnections else { return false }
        return count(instance, 0) > 0
    }

    func start(name: String) {
        lock.lock(); defer { lock.unlock() }
        guard instance == nil else { return }
        guard lib.isLoaded, let create = lib.sendCreate else {
            error = lib.error ?? "This NDI runtime can't send video"
            return
        }
        instance = name.withCString { cName in
            // NDI's clock would block the render thread; frames already arrive at the
            // source's own rate.
            var settings = NDIlib_send_create_t(p_ndi_name: cName, p_groups: nil,
                                                clock_video: false, clock_audio: false)
            return create(&settings)
        }
        if let instance {
            error = nil
            sourceName = lib.sendSourceName?(instance)?.pointee.p_ndi_name.map { String(cString: $0) }
        } else {
            error = "NDI couldn't create a sender named \u{201C}\(name)\u{201D}"
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if let instance { lib.sendDestroy?(instance) }
        instance = nil
        sourceName = nil
    }

    func publish(base: UnsafeRawPointer, width: Int, height: Int, stride: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let instance, let send = lib.sendVideo else { return }
        if let count = lib.sendConnections, count(instance, 0) == 0 { return }

        // Receivers show the frame rate, so report a smoothed measure of the real one.
        let now = CFAbsoluteTimeGetCurrent()
        let dt = now - lastSend
        lastSend = now
        if dt > 0.004, dt < 0.5 { frameInterval += (dt - frameInterval) * 0.1 }

        var frame = NDIlib_video_frame_v2_t()
        frame.xres = Int32(width)
        frame.yres = Int32(height)
        frame.FourCC = NDIlib_FourCC_type_BGRX
        frame.frame_rate_N = Int32((1000 / frameInterval).rounded())
        frame.frame_rate_D = 1000
        frame.picture_aspect_ratio = 0                  // square pixels
        frame.frame_format_type = Int32(NDIlib_frame_format_type_progressive)
        frame.timecode = NDIlib_send_timecode_synthesize
        frame.p_data = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self))
        frame.line_stride_in_bytes = Int32(stride)
        send(instance, &frame)                           // synchronous: done with `base` on return
    }

    deinit { stop() }
}
