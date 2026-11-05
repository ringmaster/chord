import AppKit

/// An invisible zone along the left edge of the window. When the pointer
/// enters it, `onPointerEntered` runs, which shows the sidebar flyout.
final class EdgeHotZoneView: NSView {
    var onPointerEntered: (() -> Void)?
    private var trackingArea: NSTrackingArea?

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
        onPointerEntered?()
    }

    /// The zone passes clicks through to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
