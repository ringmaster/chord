import AppKit

// The delegate is set here instead of through a MainMenu nib. Chord has no nib,
// and NSApplicationMain alone leaves the delegate unset.
//
// NSApplication holds its delegate weakly, so the delegate is held here for as
// long as the application runs.
enum Shell {
    @MainActor static let delegate = AppDelegate()
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = Shell.delegate
    application.setActivationPolicy(.regular)
    application.run()
}
