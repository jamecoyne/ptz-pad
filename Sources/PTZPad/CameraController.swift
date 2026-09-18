import Foundation
import Combine

/// Glue between the gamepad and the camera: maps stick/button state to VISCA,
/// rate-limits drive commands, and polls the camera for its position.
final class CameraController: ObservableObject {
    static let shared = CameraController()

    // MARK: Settings (persisted)
    @Published var host: String { didSet { defaults.set(host, forKey: "host") } }
    @Published var port: Int { didSet { defaults.set(port, forKey: "port") } }
    @Published var deadzone: Double { didSet { defaults.set(deadzone, forKey: "deadzone") } }
    @Published var speedScale: Double { didSet { defaults.set(speedScale, forKey: "speedScale") } }
    @Published var precisionScale: Double { didSet { defaults.set(precisionScale, forKey: "precisionScale") } }
    @Published var invertTilt: Bool { didSet { defaults.set(invertTilt, forKey: "invertTilt") } }
    @Published var invertPan: Bool { didSet { defaults.set(invertPan, forKey: "invertPan") } }
    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: "autoConnect") } }

    // MARK: Status
    @Published private(set) var socketReady = false
    @Published private(set) var socketError: String?
    @Published private(set) var cameraResponding = false
    @Published private(set) var pan: Int?
    @Published private(set) var tilt: Int?
    @Published private(set) var zoom: Int?
    @Published private(set) var lastSent = ""
    @Published private(set) var lastReply = ""
    @Published private(set) var log: [String] = []
    @Published private(set) var precision = false
    @Published private(set) var driving = false
    @Published private(set) var zooming = false
    @Published private(set) var panSpeedNow = 0
    @Published private(set) var tiltSpeedNow = 0
    @Published private(set) var zoomSpeedNow = 0

    let visca = ViscaClient()
    let pad = ControllerManager()

    private let defaults = UserDefaults.standard
    private var prev = PadState()
    private var lastDrive: [UInt8]?
    private var lastDriveSentAt = Date.distantPast
    private var lastZoom: [UInt8]?
    private var lastZoomSentAt = Date.distantPast
    private var pollTimer: Timer?
    private var lastReplyAt = Date.distantPast
    private let minDriveInterval: TimeInterval = 0.05
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private init() {
        host = defaults.string(forKey: "host") ?? "192.168.1.192"
        let p = defaults.integer(forKey: "port"); port = p == 0 ? 5678 : p
        deadzone = defaults.object(forKey: "deadzone") as? Double ?? 0.15
        speedScale = defaults.object(forKey: "speedScale") as? Double ?? 1.0
        precisionScale = defaults.object(forKey: "precisionScale") as? Double ?? 0.25
        invertTilt = defaults.bool(forKey: "invertTilt")
        invertPan = defaults.bool(forKey: "invertPan")
        autoConnect = defaults.object(forKey: "autoConnect") as? Bool ?? true

        visca.onReply = { [weak self] reply in
            DispatchQueue.main.async { self?.handle(reply) }
        }
        visca.onState = { [weak self] ready, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.socketReady = ready
                self.socketError = error
                self.appendLog(ready ? "UDP socket ready → \(self.host):\(self.port)" : "UDP socket closed\(error.map { ": \($0)" } ?? "")")
            }
        }
        pad.onState = { [weak self] s in self?.handle(s) }
        pad.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            if connected {
                self.appendLog("Controller connected: \(self.pad.controllerName ?? "?")")
            } else {
                self.appendLog("Controller disconnected — sending stop")
                self.stopAll()
            }
        }
    }

    func start() {
        if autoConnect { connect() }
    }

    // MARK: Connection

    func connect() {
        visca.connect(host: host, port: UInt16(clamping: port))
        pollTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollPosition() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        lastDrive = nil
        lastZoom = nil
    }

    func disconnect() {
        stopAll()
        pollTimer?.invalidate()
        pollTimer = nil
        visca.disconnect()
        socketReady = false
        cameraResponding = false
    }

    private func pollPosition() {
        guard socketReady else { return }
        visca.send(Visca.panTiltPosInq)
        visca.send(Visca.zoomPosInq)
        cameraResponding = Date().timeIntervalSince(lastReplyAt) < 2.0
    }

    // MARK: Commands

    func send(_ bytes: [UInt8], label: String) {
        visca.send(bytes)
        lastSent = "\(label)  [\(Visca.hex(bytes))]"
        appendLog("→ \(label)  \(Visca.hex(bytes))")
    }

    func home() { send(Visca.home, label: "Home") }
    func autofocus() { send(Visca.focusOnePush, label: "One-push autofocus") }
    func recallPreset(_ n: Int) { send(Visca.presetRecall(n), label: "Recall preset \(n)") }
    func savePreset(_ n: Int) { send(Visca.presetSet(n), label: "SAVE preset \(n)") }

    func stopAll() {
        visca.send(Visca.panTiltStop)
        visca.send(Visca.zoomStop)
        lastDrive = Visca.panTiltStop
        lastZoom = Visca.zoomStop
        driving = false
        zooming = false
        panSpeedNow = 0; tiltSpeedNow = 0; zoomSpeedNow = 0
        lastSent = "Stop all"
        appendLog("→ Stop pan/tilt + zoom")
    }

    // MARK: Replies

    private func handle(_ reply: ViscaReply) {
        lastReplyAt = Date()
        cameraResponding = true
        switch reply {
        case .panTilt(let p, let t):
            if pan == nil { appendLog("← camera answered: pan=\(p) tilt=\(t)") }
            pan = p; tilt = t
        case .zoom(let z):
            zoom = z
        case .ack:
            break
        case .completion:
            break
        case .error:
            lastReply = reply.description
            appendLog("← \(reply.description)")
        case .unknown:
            lastReply = reply.description
            appendLog("← \(reply.description)")
        }
        if case .panTilt = reply {} else if case .zoom = reply {} else { lastReply = reply.description }
    }

    // MARK: Gamepad → VISCA

    private func handle(_ s: PadState) {
        func pressed(_ kp: KeyPath<PadState, Bool>) -> Bool { s[keyPath: kp] && !prev[keyPath: kp] }

        if precision != s.rb { precision = s.rb }

        if pressed(\.menu) { home() }
        if pressed(\.options) { stopAll() }
        if pressed(\.rightThumb) { autofocus() }

        let presetButtons: [(KeyPath<PadState, Bool>, Int)] = [(\.a, 1), (\.b, 2), (\.x, 3), (\.y, 4)]
        for (kp, n) in presetButtons where pressed(kp) {
            if s.lb { savePreset(n) } else { recallPreset(n) }
        }

        // Pan / tilt from the left stick, with D-pad as a speed-1 nudge.
        var px = Double(s.leftX), py = Double(s.leftY)
        if invertPan { px = -px }
        if invertTilt { py = -py }
        var (panDir, panSpeed) = axisToDrive(px, max: Visca.maxPanSpeed)
        var (tiltDir, tiltSpeed) = axisToDrive(py, max: Visca.maxTiltSpeed)
        if panDir == 0 {
            if s.dpadLeft { panDir = -1; panSpeed = 1 } else if s.dpadRight { panDir = 1; panSpeed = 1 }
        }
        if tiltDir == 0 {
            if s.dpadUp { tiltDir = 1; tiltSpeed = 1 } else if s.dpadDown { tiltDir = -1; tiltSpeed = 1 }
        }
        let moving = panDir != 0 || tiltDir != 0
        let driveCmd: [UInt8] = moving
            ? Visca.panTiltDrive(panSpeed: max(panSpeed, 1), tiltSpeed: max(tiltSpeed, 1),
                                 pan: panDir < 0 ? .left : (panDir > 0 ? .right : .stop),
                                 tilt: tiltDir > 0 ? .up : (tiltDir < 0 ? .down : .stop))
            : Visca.panTiltStop
        if driveCmd != lastDrive {
            let now = Date()
            if !moving || now.timeIntervalSince(lastDriveSentAt) >= minDriveInterval {
                visca.send(driveCmd)
                lastDrive = driveCmd
                lastDriveSentAt = now
                driving = moving
                panSpeedNow = panDir == 0 ? 0 : panSpeed * panDir
                tiltSpeedNow = tiltDir == 0 ? 0 : tiltSpeed * tiltDir
                lastSent = moving
                    ? "Drive pan \(dirName(panDir, "L", "R")) \(panSpeed)  tilt \(dirName(tiltDir, "D", "U")) \(tiltSpeed)  [\(Visca.hex(driveCmd))]"
                    : "Pan/tilt stop  [\(Visca.hex(driveCmd))]"
            }
        }

        // Zoom from the right stick Y plus the triggers (RT in, LT out).
        var z = Double(s.rightY) + Double(s.rightTrigger) - Double(s.leftTrigger)
        z = min(max(z, -1), 1)
        let (zDir, zSpeed) = axisToDrive(z, max: Visca.maxZoomSpeed)
        let zoomCmd = zDir == 0 ? Visca.zoomStop : Visca.zoom(zDir * max(zSpeed, 1))
        if zoomCmd != lastZoom {
            let now = Date()
            if zDir == 0 || now.timeIntervalSince(lastZoomSentAt) >= minDriveInterval {
                visca.send(zoomCmd)
                lastZoom = zoomCmd
                lastZoomSentAt = now
                zooming = zDir != 0
                zoomSpeedNow = zDir == 0 ? 0 : zSpeed * zDir
                lastSent = zDir == 0
                    ? "Zoom stop  [\(Visca.hex(zoomCmd))]"
                    : "Zoom \(zDir > 0 ? "in" : "out") \(zSpeed)  [\(Visca.hex(zoomCmd))]"
            }
        }

        prev = s
    }

    /// Maps a -1…1 axis to (direction, speed). Applies deadzone, an expo curve,
    /// the global speed scale, and the precision (RB) scale.
    private func axisToDrive(_ v: Double, max maxSpeed: Int) -> (Int, Int) {
        let a = abs(v)
        guard a > deadzone else { return (0, 0) }
        let n = (a - deadzone) / (1 - deadzone)
        let curved = pow(n, 1.6)
        let scale = speedScale * (precision ? precisionScale : 1)
        let sp = Swift.max(1, Int((curved * Double(maxSpeed) * scale).rounded()))
        return (v > 0 ? 1 : -1, sp)
    }

    private func dirName(_ d: Int, _ neg: String, _ pos: String) -> String {
        d < 0 ? neg : (d > 0 ? pos : "-")
    }

    // MARK: Log

    private func appendLog(_ line: String) {
        let stamped = "\(timeFormatter.string(from: Date()))  \(line)"
        log.append(stamped)
        if log.count > 200 { log.removeFirst(log.count - 200) }
        print(stamped)
        fflush(stdout)
    }
}
