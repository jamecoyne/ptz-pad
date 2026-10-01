import SwiftUI

struct ContentView: View {
    @ObservedObject var camera = CameraController.shared
    @State private var saveMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionBar
                VideoPanel()
                HStack(alignment: .top, spacing: 14) {
                    ControllerPanel(pad: camera.pad, camera: camera)
                    positionPanel
                }
                actionsPanel
                settingsPanel
                MappingPanel()
                logPanel
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 720)
    }

    // MARK: Sections

    private var connectionBar: some View {
        GroupBox("Camera") {
            HStack(spacing: 10) {
                TextField("Host", text: $camera.host)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                TextField("Port", value: $camera.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                if camera.socketReady {
                    Button("Disconnect") { camera.disconnect() }
                } else {
                    Button("Connect") { camera.connect() }
                        .keyboardShortcut(.defaultAction)
                }
                Toggle("Auto-connect", isOn: $camera.autoConnect)
                    .toggleStyle(.checkbox)
                Spacer()
                StatusDot(on: camera.socketReady, label: "Socket")
                StatusDot(on: camera.cameraResponding, label: "Camera replying")
            }
            .padding(6)
            if let err = camera.socketError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            CameraFinderView()
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
        }
    }

    private var positionPanel: some View {
        GroupBox("Position") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    Readout(label: "Pan", value: camera.pan)
                    Readout(label: "Tilt", value: camera.tilt)
                    Readout(label: "Zoom", value: camera.zoom)
                }
                HStack(spacing: 6) {
                    ModeChip("DRIVING", on: camera.driving)
                    ModeChip("ZOOMING", on: camera.zooming)
                    ModeChip("PRECISION", on: camera.precision)
                }
                Text("speeds  pan \(camera.panSpeedNow)  tilt \(camera.tiltSpeedNow)  zoom \(camera.zoomSpeedNow)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(camera.lastSent)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !camera.lastReply.isEmpty {
                    Text("← \(camera.lastReply)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsPanel: some View {
        GroupBox("Actions") {
            HStack(spacing: 8) {
                Button("Home") { camera.home() }
                Button("Stop") { camera.stopAll() }
                Button("Autofocus") { camera.autofocus() }
                Divider().frame(height: 18)
                ForEach(1...4, id: \.self) { n in
                    Button(saveMode ? "Save \(n)" : "Preset \(n)") {
                        if saveMode { camera.savePreset(n) } else { camera.recallPreset(n) }
                    }
                    .tint(saveMode ? .orange : nil)
                }
                Toggle("Save mode", isOn: $saveMode).toggleStyle(.checkbox)
                Spacer()
            }
            .disabled(!camera.socketReady)
            .padding(6)
        }
    }

    private var settingsPanel: some View {
        GroupBox("Feel") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Max speed")
                    Slider(value: $camera.speedScale, in: 0.1...1.0)
                    Text("\(Int(camera.speedScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                GridRow {
                    Text("Precision (RB)")
                    Slider(value: $camera.precisionScale, in: 0.05...0.6)
                    Text("\(Int(camera.precisionScale * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                GridRow {
                    Text("Deadzone")
                    Slider(value: $camera.deadzone, in: 0.05...0.4)
                    Text("\(Int(camera.deadzone * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                GridRow {
                    Text("Invert")
                    HStack {
                        Toggle("Tilt", isOn: $camera.invertTilt).toggleStyle(.checkbox)
                        Toggle("Pan", isOn: $camera.invertPan).toggleStyle(.checkbox)
                    }
                    Text("")
                }
            }
            .padding(6)
        }
    }

    private var logPanel: some View {
        GroupBox("Log") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(camera.log.suffix(8).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if camera.log.isEmpty {
                    Text("—").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .padding(6)
        }
    }
}

// MARK: - Controller panel

struct ControllerPanel: View {
    @ObservedObject var pad: ControllerManager
    @ObservedObject var camera: CameraController

    var body: some View {
        GroupBox("Controller") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(on: pad.isConnected, label: pad.controllerName ?? "No controller — pair it in System Settings › Bluetooth")
                    if let b = pad.batteryLevel, b >= 0 {
                        Text("\(Int(b * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 18) {
                    StickView(x: pad.state.leftX, y: pad.state.leftY, pressed: pad.state.leftThumb, label: "pan / tilt")
                    StickView(x: pad.state.rightX, y: pad.state.rightY, pressed: pad.state.rightThumb, label: "zoom")
                    VStack(alignment: .leading, spacing: 4) {
                        TriggerBar(label: "LT", value: pad.state.leftTrigger)
                        TriggerBar(label: "RT", value: pad.state.rightTrigger)
                    }
                }
                HStack(spacing: 4) {
                    ButtonChip("A", pad.state.a); ButtonChip("B", pad.state.b)
                    ButtonChip("X", pad.state.x); ButtonChip("Y", pad.state.y)
                    ButtonChip("LB", pad.state.lb); ButtonChip("RB", pad.state.rb)
                    ButtonChip("☰", pad.state.menu); ButtonChip("⧉", pad.state.options)
                    ButtonChip("▲", pad.state.dpadUp); ButtonChip("▼", pad.state.dpadDown)
                    ButtonChip("◀", pad.state.dpadLeft); ButtonChip("▶", pad.state.dpadRight)
                }
            }
            .padding(6)
        }
    }
}

struct StickView: View {
    let x: Float, y: Float, pressed: Bool, label: String
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                Circle().fill(Color.secondary.opacity(0.08))
                Path { p in
                    p.move(to: CGPoint(x: 36, y: 0)); p.addLine(to: CGPoint(x: 36, y: 72))
                    p.move(to: CGPoint(x: 0, y: 36)); p.addLine(to: CGPoint(x: 72, y: 36))
                }.stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                Circle()
                    .fill(pressed ? Color.orange : Color.accentColor)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(x) * 30, y: CGFloat(-y) * 30)
            }
            .frame(width: 72, height: 72)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TriggerBar: View {
    let label: String
    let value: Float
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption2).frame(width: 18)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3).fill(Color.accentColor)
                        .frame(width: g.size.width * CGFloat(value))
                }
            }
            .frame(width: 80, height: 10)
        }
    }
}

struct ButtonChip: View {
    let label: String
    let on: Bool
    init(_ label: String, _ on: Bool) { self.label = label; self.on = on }
    var body: some View {
        Text(label)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(on ? Color.white : Color.primary)
    }
}

struct ModeChip: View {
    let label: String
    let on: Bool
    init(_ label: String, on: Bool) { self.label = label; self.on = on }
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(on ? Color.green : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(on ? Color.white : Color.secondary)
    }
}

struct StatusDot: View {
    let on: Bool
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 9, height: 9)
            Text(label).font(.caption)
        }
    }
}

struct Readout: View {
    let label: String
    let value: Int?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "—")
                .font(.system(size: 22, weight: .medium, design: .monospaced))
        }
    }
}

// MARK: - Mapping legend

struct MappingPanel: View {
    private let rows: [(String, String)] = [
        ("Left stick", "Pan (X) and tilt (Y). Speed follows how far you push."),
        ("D-pad", "Nudge pan/tilt at the slowest speed."),
        ("Right stick ↑↓", "Zoom in / out, proportional."),
        ("RT / LT", "Zoom in / out, proportional (same as right stick)."),
        ("RB (hold)", "Precision mode: all speeds scaled down."),
        ("A B X Y", "Recall preset 1 / 2 / 3 / 4."),
        ("LB + A B X Y", "Save the current shot to preset 1 / 2 / 3 / 4."),
        ("Menu ☰", "Go to home position."),
        ("View ⧉", "Stop everything."),
        ("Right stick click", "One-push autofocus."),
    ]
    var body: some View {
        GroupBox("Mapping") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).font(.system(.caption, design: .rounded).weight(.semibold))
                        Text(r.1).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
