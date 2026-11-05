import Testing
@testable import chord_logic

struct SidebarFlyoutTests {
    @Test func startsHiddenAndUnpinned() {
        let flyout = SidebarFlyout()
        #expect(!flyout.isVisible)
        #expect(!flyout.isPinned)
    }

    @Test func reachingTheEdgeShowsItAndSchedulesAHide() {
        var flyout = SidebarFlyout()
        #expect(flyout.handle(.pointerReachedEdge) == .scheduleHide)
        #expect(flyout.isVisible)
    }

    @Test func hideDelayHidesWhenThePointerIsOutside() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.pointerReachedEdge)
        #expect(flyout.handle(.hideDelayElapsed(pointerInsideSidebar: false)) == .none)
        #expect(!flyout.isVisible)
    }

    @Test func hideDelayKeepsItWhenThePointerIsInside() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.pointerReachedEdge)
        _ = flyout.handle(.hideDelayElapsed(pointerInsideSidebar: true))
        #expect(flyout.isVisible)
    }

    @Test func leavingTheSidebarSchedulesAHide() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.pointerReachedEdge)
        #expect(flyout.handle(.pointerLeftSidebar) == .scheduleHide)
    }

    @Test func leavingWhileHiddenDoesNothing() {
        var flyout = SidebarFlyout()
        #expect(flyout.handle(.pointerLeftSidebar) == .none)
        #expect(!flyout.isVisible)
    }

    @Test func togglePinsAndShows() {
        var flyout = SidebarFlyout()
        #expect(flyout.handle(.togglePinned) == .none)
        #expect(flyout.isPinned)
        #expect(flyout.isVisible)
    }

    @Test func pinnedIgnoresLeavingAndTheHideDelay() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.togglePinned)
        #expect(flyout.handle(.pointerLeftSidebar) == .none)
        _ = flyout.handle(.hideDelayElapsed(pointerInsideSidebar: false))
        #expect(flyout.isVisible)
    }

    @Test func reachingTheEdgeWhilePinnedSchedulesNothing() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.togglePinned)
        #expect(flyout.handle(.pointerReachedEdge) == .none)
    }

    @Test func toggleAgainUnpinsAndHides() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.togglePinned)
        _ = flyout.handle(.togglePinned)
        #expect(!flyout.isPinned)
        #expect(!flyout.isVisible)
    }

    @Test func toggleWhileShownByHoverPinsIt() {
        var flyout = SidebarFlyout()
        _ = flyout.handle(.pointerReachedEdge)
        _ = flyout.handle(.togglePinned)
        #expect(flyout.isPinned)
        #expect(flyout.isVisible)
    }
}
