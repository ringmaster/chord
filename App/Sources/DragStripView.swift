import AppKit

/// A transparent strip over the top edge of the page that drags the window.
///
/// The page still renders under the strip. When the pointer is over the strip,
/// a small grabber fades in to show that it drags. A double-click acts as a
/// double-click on a title bar, using the user's system setting.
final class DragStripView: NSView {
    private let grabber = CALayer()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        grabber.backgroundColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        grabber.cornerRadius = Design.Edge.grabberSize.height / 2
        grabber.opacity = 0
        layer?.addSublayer(grabber)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DragStripView is created in code only")
    }

    override func layout() {
        super.layout()
        let size = Design.Edge.grabberSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grabber.frame = NSRect(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2,
                               width: size.width, height: size.height)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            grabber.backgroundColor = NSColor.labelColor.withAlphaComponent(0.35).cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setGrabberVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        setGrabberVisible(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitleBarDoubleClickAction()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    private func setGrabberVisible(_ visible: Bool) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = grabber.presentation()?.opacity ?? grabber.opacity
        animation.toValue = visible ? 1 : 0
        animation.duration = Design.Edge.grabberFadeDuration
        grabber.opacity = visible ? 1 : 0
        grabber.add(animation, forKey: "opacity")
    }
}

extension NSWindow {
    /// Does what a double-click on the title bar does, as set in System
    /// Settings > Desktop & Dock > "Double-click a window's title bar to".
    func performTitleBarDoubleClickAction() {
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "Minimize":
            performMiniaturize(nil)
        case "None":
            break
        default:
            performZoom(nil)
        }
    }
}
