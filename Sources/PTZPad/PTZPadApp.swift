import SwiftUI
import AppKit

@main
struct PTZPadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("PTZ Pad") {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 800, height: 1000)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare binary (swift run) so the window and menu bar appear.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        CameraController.shared.start()
        VideoController.shared.start()
        CameraLocator.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the camera driving.
        CameraController.shared.stopAll()
        VideoController.shared.shutdown()
        Thread.sleep(forTimeInterval: 0.15)
    }
}
