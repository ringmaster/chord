import Observation

/// Runs `apply` now, and again each time an observable value that `apply`
/// read changes. Use it to keep AppKit views in step with `@Observable` state.
@MainActor
func keepUpdated(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in keepUpdated(apply) }
    }
}
