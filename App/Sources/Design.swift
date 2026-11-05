import AppKit

/// Shared sizes, timings, and colors for Chord's own UI. Change a value here,
/// not at the place it is used, so the whole app stays consistent.
enum Design {
    enum Sidebar {
        static let width: CGFloat = 264
        /// The gap between the flyout card and the window edges.
        static let inset: CGFloat = 8
        static let cornerRadius: CGFloat = 14
        /// The height of the area at the top of the card that holds the window buttons.
        static let headerHeight: CGFloat = 40
        static let contentPadding: CGFloat = 14
        static let slideDuration: TimeInterval = 0.22
        /// How long the flyout stays after the pointer leaves it.
        static let hideDelay: Duration = .milliseconds(350)
    }

    enum Edge {
        /// The width of the invisible zone at the left edge that shows the sidebar.
        static let hotZoneWidth: CGFloat = 5
        /// The height of the drag strip over the top edge of the page.
        static let dragStripHeight: CGFloat = 10
        static let grabberSize = NSSize(width: 40, height: 4)
        static let grabberFadeDuration: TimeInterval = 0.15
    }

    @MainActor enum Motion {
        static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
    }

    @MainActor enum Text {
        static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
        static let detail = NSFont.systemFont(ofSize: 11, weight: .regular)
    }
}
