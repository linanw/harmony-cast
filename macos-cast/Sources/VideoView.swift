import AppKit
import AVFoundation

final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onToggleFullScreen: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onToggleFullScreen?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, window?.styleMask.contains(.fullScreen) == true {
            window?.toggleFullScreen(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    func reset() {
        displayLayer.flushAndRemoveImage()
    }
}
