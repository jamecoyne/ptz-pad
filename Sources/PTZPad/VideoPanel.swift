import SwiftUI

/// NDI preview, picture adjustments, effect, detection and Syphon output.
struct VideoPanel: View {
    @ObservedObject var video = VideoController.shared

    var body: some View {
        GroupBox("Video") {
            VStack(alignment: .leading, spacing: 10) {
                sourceBar
                VideoPreview(layer: video.previewLayer)
                    .aspectRatio(aspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if video.frameSize == nil {
                            Text(placeholder)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                HStack(alignment: .top, spacing: 14) {
                    pictureControls
                    VStack(alignment: .leading, spacing: 10) {
                        detectionControls
                        Divider()
                        syphonControls
                    }
                    .frame(width: 250, alignment: .leading)
                }
            }
            .padding(6)
        }
    }

    private var aspect: CGFloat {
        guard let s = video.frameSize, s.height > 0 else { return 16.0 / 9.0 }
        return s.width / s.height
    }

    private var placeholder: String {
        if let err = video.ndiError { return err }
        if video.connectedSource != nil { return "Waiting for video…" }
        if video.sources.isEmpty { return "Looking for NDI sources…" }
        return "Pick an NDI source"
    }

    private var sourceBar: some View {
        HStack(spacing: 10) {
            Picker("NDI", selection: $video.sourceName) {
                Text("None").tag("")
                ForEach(video.sources) { s in
                    Text(s.url.isEmpty ? s.name : "\(s.name)  ·  \(s.host)").tag(s.name)
                }
                // Keep a remembered source selectable while it's offline.
                if !video.sourceName.isEmpty, !video.sources.contains(where: { $0.name == video.sourceName }) {
                    Text("\(video.sourceName) (offline)").tag(video.sourceName)
                }
            }
            .frame(maxWidth: 380)
            Spacer()
            if let s = video.frameSize {
                Text("\(Int(s.width))×\(Int(s.height))  \(Int(video.fps.rounded())) fps")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            StatusDot(on: video.frameSize != nil, label: "NDI")
        }
    }

    private var pictureControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("Brightness")
                Slider(value: $video.brightness, in: -0.5...0.5)
                Text(String(format: "%+.2f", video.brightness)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            GridRow {
                Text("Contrast")
                Slider(value: $video.contrast, in: 0.25...2)
                Text(String(format: "%.2f", video.contrast)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            GridRow {
                Text("Saturation")
                Slider(value: $video.saturation, in: 0...2)
                Text(String(format: "%.2f", video.saturation)).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Button("Reset picture") { video.resetPicture() }
                    .controlSize(.small)
                Text("")
            }
            Divider().gridCellColumns(3)
            GridRow {
                Text("Effect")
                Picker("", selection: $video.effect) {
                    ForEach(VideoEffect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Text("")
            }
            GridRow {
                Text(video.effect.amountLabel)
                Slider(value: $video.effectAmount, in: 0...1)
                    .disabled(video.effect == .none)
                Text("\(Int(video.effectAmount * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var detectionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Detection boxes", isOn: $video.detectionEnabled).toggleStyle(.checkbox)
                Spacer()
                if video.detectionEnabled {
                    Text("\(video.detectionCount) found").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Toggle("Faces", isOn: $video.detectFaces)
                Toggle("Bodies", isOn: $video.detectBodies)
                Toggle("Eyes", isOn: $video.detectEyes)
            }
            .toggleStyle(.checkbox)
            .disabled(!video.detectionEnabled)
            HStack(spacing: 10) {
                Toggle("Mouths", isOn: $video.detectMouths)
                Toggle("Labels", isOn: $video.showLabels)
            }
            .toggleStyle(.checkbox)
            .disabled(!video.detectionEnabled)
        }
    }

    private var syphonControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Syphon output", isOn: $video.syphonEnabled).toggleStyle(.checkbox)
                Spacer()
                if video.syphonEnabled {
                    StatusDot(on: video.syphonClients, label: video.syphonClients ? "client" : "no client")
                }
            }
            HStack(spacing: 6) {
                TextField("Name", text: $video.syphonName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { video.applySyphonName() }
                Toggle("Flip", isOn: $video.syphonFlip).toggleStyle(.checkbox)
            }
            .disabled(!video.syphonEnabled)
        }
    }
}
