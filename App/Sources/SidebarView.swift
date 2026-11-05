import AppKit
import SwiftUI

/// The sidebar card: a glass panel at the left of the window that hosts
/// `SidebarContent`.
///
/// The top of the card is left empty for the window buttons, which the window
/// controller places there. Empty areas of the card drag the window.
final class SidebarView: NSView {
    /// Runs when the pointer leaves the card.
    var onPointerExited: (() -> Void)?

    private let glass = NSGlassEffectView()
    private var trackingArea: NSTrackingArea?

    init(content: SidebarContent) {
        super.init(frame: .zero)
        glass.cornerRadius = Design.Sidebar.cornerRadius
        glass.contentView = NSHostingView(rootView: content)
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarView is created in code only")
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
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

    override func mouseExited(with event: NSEvent) {
        onPointerExited?()
    }
}
