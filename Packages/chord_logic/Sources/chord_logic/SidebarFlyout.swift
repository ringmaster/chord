/// Decides when the sidebar flyout is visible.
///
/// The flyout appears when the pointer reaches the left edge of the window, and
/// hides a short time after the pointer leaves it. A keyboard toggle pins it
/// open, and the same toggle unpins and hides it.
///
/// The caller owns the timer. When `handle` returns `.scheduleHide`, the caller
/// starts the hide delay (restarting it if one is running). When the delay
/// ends, the caller sends `.hideDelayElapsed` with the pointer's position at
/// that moment. The pointer position is read then, not tracked through events,
/// because a view that slides in under a still pointer gets no enter event.
public struct SidebarFlyout: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case pointerReachedEdge
        case pointerLeftSidebar
        case hideDelayElapsed(pointerInsideSidebar: Bool)
        case togglePinned
    }

    public enum Effect: Equatable, Sendable {
        case none
        case scheduleHide
    }

    public private(set) var isVisible = false
    public private(set) var isPinned = false

    public init() {}

    public mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .pointerReachedEdge:
            isVisible = true
            return isPinned ? .none : .scheduleHide

        case .pointerLeftSidebar:
            return (isVisible && !isPinned) ? .scheduleHide : .none

        case .hideDelayElapsed(let pointerInsideSidebar):
            if !isPinned && !pointerInsideSidebar {
                isVisible = false
            }
            return .none

        case .togglePinned:
            isPinned.toggle()
            isVisible = isPinned
            return .none
        }
    }
}
