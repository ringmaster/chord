import AppKit

/// The sidebar flyout: a floating glass card at the left of the window.
///
/// The card's background drags the window. The top of the card is left empty
/// for the window buttons, which the window controller places there.
/// For now the card shows the current page's title and host; spaces,
/// favorites, pinned sites, and tabs come in a later phase.
final class SidebarView: NSView {
    /// Runs when the pointer leaves the card.
    var onPointerExited: (() -> Void)?

    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glass.cornerRadius = Design.Sidebar.cornerRadius
        glass.contentView = content
        addSubview(glass)

        for label in [titleLabel, hostLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            content.addSubview(label)
        }
        titleLabel.font = Design.Text.title
        titleLabel.textColor = .labelColor
        hostLabel.font = Design.Text.detail
        hostLabel.textColor = .secondaryLabelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarView is created in code only")
    }

    func show(title: String, host: String) {
        titleLabel.stringValue = title
        hostLabel.stringValue = host
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds

        let padding = Design.Sidebar.contentPadding
        let width = bounds.width - padding * 2
        let top = bounds.height - Design.Sidebar.headerHeight
        titleLabel.frame = NSRect(x: padding, y: top - 22, width: width, height: 18)
        hostLabel.frame = NSRect(x: padding, y: top - 40, width: width, height: 16)
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

    /// A click on the card's background, or on a label, drags the window.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performTitleBarDoubleClickAction()
        } else {
            window?.performDrag(with: event)
        }
    }
}
