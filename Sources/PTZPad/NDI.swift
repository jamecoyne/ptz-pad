import Foundation
import CBridge

/// The NDI runtime, loaded with dlopen so the app builds without the SDK and still runs
/// (minus video) on a Mac that has no NDI installed.
///
/// NDI Tools, the NDI SDK and the standalone runtime all put `libndi.dylib` somewhere
/// predictable; Resolume ships its own copy too. The first one that loads wins.
final class NDILibrary {
    static let shared = NDILibrary()

    private(set) var path: String?
    private(set) var error: String?

    let initialize: NDIlib_initialize_f?
    let findCreate: NDIlib_find_create_v2_f?
    let findDestroy: NDIlib_find_destroy_f?
    let findSources: NDIlib_find_get_current_sources_f?
    let recvCreate: NDIlib_recv_create_v3_f?
    let recvDestroy: NDIlib_recv_destroy_f?
    let recvCapture: NDIlib_recv_capture_v2_f?
    let recvFreeVideo: NDIlib_recv_free_video_v2_f?
    let sendCreate: NDIlib_send_create_f?
    let sendDestroy: NDIlib_send_destroy_f?
    let sendVideo: NDIlib_send_send_video_v2_f?
    let sendConnections: NDIlib_send_get_no_connections_f?
    let sendSourceName: NDIlib_send_get_source_name_f?

    var isLoaded: Bool { recvCapture != nil }

    private static var candidates: [String] {
        let env = ProcessInfo.processInfo.environment
        var paths = ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"].compactMap { env[$0] }.map { "\($0)/libndi.dylib" }
        paths += [
            "/usr/local/lib/libndi.dylib",
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            "/Applications/NDI Video Monitor.app/Contents/Frameworks/libndi.dylib",
            "/Applications/NDI Launcher.app/Contents/Frameworks/libndi.dylib",
            "/Applications/NDI Scan Converter.app/Contents/Frameworks/libndi.dylib",
            "/Applications/Resolume Arena/libndi.dylib",
            "/Applications/Resolume Avenue/libndi.dylib",
        ]
        return paths
    }

    private init() {
        var handle: UnsafeMutableRawPointer?
        for candidate in NDILibrary.candidates where FileManager.default.fileExists(atPath: candidate) {
            if let h = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) {
                handle = h
                path = candidate
                break
            }
            error = String(cString: dlerror())
        }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let handle, let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        initialize = sym("NDIlib_initialize", NDIlib_initialize_f.self)
        findCreate = sym("NDIlib_find_create_v2", NDIlib_find_create_v2_f.self)
        findDestroy = sym("NDIlib_find_destroy", NDIlib_find_destroy_f.self)
        findSources = sym("NDIlib_find_get_current_sources", NDIlib_find_get_current_sources_f.self)
        recvCreate = sym("NDIlib_recv_create_v3", NDIlib_recv_create_v3_f.self)
        recvDestroy = sym("NDIlib_recv_destroy", NDIlib_recv_destroy_f.self)
        recvCapture = sym("NDIlib_recv_capture_v2", NDIlib_recv_capture_v2_f.self)
        recvFreeVideo = sym("NDIlib_recv_free_video_v2", NDIlib_recv_free_video_v2_f.self)
        sendCreate = sym("NDIlib_send_create", NDIlib_send_create_f.self)
        sendDestroy = sym("NDIlib_send_destroy", NDIlib_send_destroy_f.self)
        sendVideo = sym("NDIlib_send_send_video_v2", NDIlib_send_send_video_v2_f.self)
        sendConnections = sym("NDIlib_send_get_no_connections", NDIlib_send_get_no_connections_f.self)
        sendSourceName = sym("NDIlib_send_get_source_name", NDIlib_send_get_source_name_f.self)

        if handle == nil {
            error = error ?? "NDI runtime not found — install NDI Tools (ndi.video/tools)"
        } else if !isLoaded {
            error = "\(path ?? "libndi") is missing expected NDI functions"
        } else if initialize?() == false {
            error = "NDI refused to initialize (unsupported CPU?)"
        } else {
            error = nil
        }
    }
}

struct NDISource: Hashable, Identifiable {
    let name: String
    let url: String
    var id: String { name }

    /// "192.168.1.192" out of "192.168.1.192:5961".
    var host: String { url.split(separator: ":").first.map(String.init) ?? url }
}

/// Watches the network for NDI sources.
final class NDIFinder {
    /// Called on the main queue whenever the list changes.
    var onChange: (([NDISource]) -> Void)?

    private let lib = NDILibrary.shared
    private var instance: NDIlib_find_instance_t?
    private var timer: DispatchSourceTimer?
    private var last: [NDISource] = []
    private let queue = DispatchQueue(label: "ptzpad.ndi.find")

    func start() {
        guard lib.isLoaded, instance == nil, let create = lib.findCreate else { return }
        var settings = NDIlib_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
        instance = create(&settings)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.3, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            if let instance { lib.findDestroy?(instance) }
            instance = nil
        }
    }

    private func poll() {
        guard let instance, let get = lib.findSources else { return }
        var count: UInt32 = 0
        guard let raw = get(instance, &count) else { return }
        let sources = (0..<Int(count)).map { i -> NDISource in
            let s = raw[i]
            return NDISource(name: s.p_ndi_name.map { String(cString: $0) } ?? "?",
                             url: s.p_url_address.map { String(cString: $0) } ?? "")
        }.sorted { $0.name < $1.name }
        guard sources != last else { return }
        last = sources
        DispatchQueue.main.async { [weak self] in self?.onChange?(sources) }
    }
}

/// Receives one NDI source on its own thread. Each video frame is handed to `onFrame`
/// synchronously and freed straight after, so the callback must finish with the pixels
/// before it returns.
final class NDIReceiver {
    /// Called on the receive thread. BGRA (or BGRX) pixels, `stride` bytes per row.
    var onFrame: ((_ data: UnsafeMutableRawPointer, _ width: Int, _ height: Int, _ stride: Int) -> Void)?

    let source: NDISource
    private let lib = NDILibrary.shared
    private var instance: NDIlib_recv_instance_t?
    private var thread: Thread?
    private let running = Atomic(false)
    private let finished = DispatchSemaphore(value: 0)

    init?(source: NDISource) {
        self.source = source
        guard lib.isLoaded, let create = lib.recvCreate else { return nil }
        instance = source.name.withCString { name in
            source.url.withCString { url in
                "PTZ Pad".withCString { recvName in
                    var settings = NDIlib_recv_create_v3_t(
                        source_to_connect_to: NDIlib_source_t(p_ndi_name: name,
                                                              p_url_address: source.url.isEmpty ? nil : url),
                        color_format: NDIlib_recv_color_format_BGRX_BGRA,
                        bandwidth: NDIlib_recv_bandwidth_highest,
                        allow_video_fields: false,
                        p_ndi_recv_name: recvName)
                    return create(&settings)
                }
            }
        }
        guard instance != nil else { return nil }
    }

    func start() {
        guard thread == nil else { return }
        running.value = true
        let t = Thread { [weak self] in self?.loop() }
        t.name = "ptzpad.ndi.recv"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    /// Blocks until the receive loop has exited, then tears the receiver down.
    func stop() {
        if thread != nil {
            running.value = false
            finished.wait()
            thread = nil
        }
        if let instance { lib.recvDestroy?(instance) }
        instance = nil
    }

    deinit { stop() }

    private func loop() {
        defer { finished.signal() }
        guard let instance, let capture = lib.recvCapture, let free = lib.recvFreeVideo else { return }
        var frame = NDIlib_video_frame_v2_t()
        while running.value {
            let type = capture(instance, &frame, nil, nil, 250)
            guard type == NDIlib_frame_type_video else { continue }
            if let data = frame.p_data, frame.xres > 0, frame.yres > 0,
               frame.FourCC == NDIlib_FourCC_type_BGRA || frame.FourCC == NDIlib_FourCC_type_BGRX {
                let stride = frame.line_stride_in_bytes > 0 ? Int(frame.line_stride_in_bytes) : Int(frame.xres) * 4
                onFrame?(UnsafeMutableRawPointer(data), Int(frame.xres), Int(frame.yres), stride)
            }
            free(instance, &frame)
        }
    }
}

/// A lock-protected value, for flags shared between the main thread and a worker.
final class Atomic<T> {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
