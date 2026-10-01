import AppKit
import SwiftUI

/// Under the Camera bar: follow-by-NDI, the subnet warning and the scan.
struct CameraFinderView: View {
    @ObservedObject var locator = CameraLocator.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Toggle("Follow camera via NDI", isOn: $locator.followNDI)
                    .toggleStyle(.checkbox)
                    .help("If the camera stops answering and its NDI source appears at a new IP, switch to it.")
                if let name = locator.cameraNDIName {
                    Text("“\(name)”").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Forget") { locator.forgetNDIName() }.controlSize(.small)
                } else {
                    Text("learns the name once the camera answers").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if locator.scanning { ProgressView().controlSize(.small) }
                Button(locator.scanning ? "Scanning…" : "Scan network") { locator.scan() }
                    .disabled(locator.scanning)
                    .help("Ask every address on this Mac's networks for a VISCA reply.")
            }

            if let w = locator.subnetWarning { warning(w) }

            if let summary = locator.scanSummary {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                    ForEach(locator.scanResults) { hit in
                        HStack(spacing: 8) {
                            Text(hit.ip).font(.system(.body, design: .monospaced))
                            if let name = hit.ndiName {
                                Text(name).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Use") { locator.use(hit.ip) }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func warning(_ w: SubnetWarning) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(w.cameraIP) isn't on this Mac's network (\(w.localNetworks)).",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            Text("Best fix: set the camera to DHCP in its web page. To reach it until then, give this Mac a second address on the camera's subnet (needs your admin password; lasts until restart or network change):")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            CommandRow(command: w.aliasCommand)
            Text("Remove it afterwards with:").font(.caption)
            CommandRow(command: w.removeCommand)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct CommandRow: View {
    let command: String
    var body: some View {
        HStack {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
        }
    }
}
