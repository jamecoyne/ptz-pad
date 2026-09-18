import Foundation
import GameController
import Combine

struct PadState: Equatable {
    var leftX: Float = 0, leftY: Float = 0
    var rightX: Float = 0, rightY: Float = 0
    var leftTrigger: Float = 0, rightTrigger: Float = 0
    var a = false, b = false, x = false, y = false
    var lb = false, rb = false
    var menu = false, options = false
    var dpadUp = false, dpadDown = false, dpadLeft = false, dpadRight = false
    var leftThumb = false, rightThumb = false
}

/// Watches for game controllers (Xbox over Bluetooth included) and polls the
/// active one at 30 Hz, publishing a snapshot of every axis and button.
final class ControllerManager: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var batteryLevel: Float?
    @Published private(set) var state = PadState()

    var onState: ((PadState) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var controller: GCController?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        // Keep receiving input even when another app is frontmost.
        GCController.shouldMonitorBackgroundEvents = true

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            self?.attach(n.object as? GCController)
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] n in
            self?.detach(n.object as? GCController)
        })
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        if let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            attach(c)
        }

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func attach(_ c: GCController?) {
        guard let c, c.extendedGamepad != nil, controller == nil else { return }
        controller = c
        controllerName = c.vendorName ?? "Game controller"
        isConnected = true
        c.playerIndex = .index1
        onConnectionChange?(true)
    }

    private func detach(_ c: GCController?) {
        guard let c, c === controller else { return }
        controller = nil
        isConnected = false
        controllerName = nil
        batteryLevel = nil
        state = PadState()
        onState?(state)
        onConnectionChange?(false)
        if let next = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            attach(next)
        }
    }

    private func poll() {
        guard let c = controller, let gp = c.extendedGamepad else { return }
        var s = PadState()
        s.leftX = gp.leftThumbstick.xAxis.value
        s.leftY = gp.leftThumbstick.yAxis.value
        s.rightX = gp.rightThumbstick.xAxis.value
        s.rightY = gp.rightThumbstick.yAxis.value
        s.leftTrigger = gp.leftTrigger.value
        s.rightTrigger = gp.rightTrigger.value
        s.a = gp.buttonA.isPressed
        s.b = gp.buttonB.isPressed
        s.x = gp.buttonX.isPressed
        s.y = gp.buttonY.isPressed
        s.lb = gp.leftShoulder.isPressed
        s.rb = gp.rightShoulder.isPressed
        s.menu = gp.buttonMenu.isPressed
        s.options = gp.buttonOptions?.isPressed ?? false
        s.dpadUp = gp.dpad.up.isPressed
        s.dpadDown = gp.dpad.down.isPressed
        s.dpadLeft = gp.dpad.left.isPressed
        s.dpadRight = gp.dpad.right.isPressed
        s.leftThumb = gp.leftThumbstickButton?.isPressed ?? false
        s.rightThumb = gp.rightThumbstickButton?.isPressed ?? false

        let level = c.battery?.batteryLevel
        if level != batteryLevel { batteryLevel = level }
        if s != state { state = s }
        onState?(s)
    }
}
