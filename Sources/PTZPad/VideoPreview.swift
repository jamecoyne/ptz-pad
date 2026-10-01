import AppKit
import SwiftUI

/// Hosts `VideoController.previewLayer`, which the render thread fills with each output
/// frame's IOSurface — so the preview is exactly what goes out over Syphon.
struct VideoPreview: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.hosted = layer
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {}
}

final class PreviewHostView: NSView {
    var hosted: CALayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            if let hosted { layer?.addSublayer(hosted) }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}
