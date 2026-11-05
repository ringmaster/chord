import AppKit
import WebKit

/// Docks Web Inspector inside the page area, using WebKit's private
/// `_WKInspector` object. This is private API, which is why Chord ships
/// outside the Mac App Store.
///
/// Every call checks that the private method exists first. When WebKit
/// changes and a method is gone, `toggle` returns false and changes nothing,
/// and Web Inspector stays reachable from Safari's Develop menu, because
/// every web view is inspectable.
@MainActor
enum WebInspector {
    /// The web views whose inspector Chord has docked.
    private static var docked: Set<ObjectIdentifier> = []

    static func isDocked(_ webView: WKWebView) -> Bool {
        docked.contains(ObjectIdentifier(webView))
    }

    /// Shows and docks the inspector for `webView`, or closes it when it is
    /// docked. Returns false when the private API is not available.
    @discardableResult
    static func toggle(_ webView: WKWebView) -> Bool {
        guard let inspector = inspector(of: webView) else { return false }
        let id = ObjectIdentifier(webView)
        if docked.contains(id) {
            guard call(inspector, "close") else { return false }
            docked.remove(id)
        } else {
            // WebKit opens its own inspector only when the private developer
            // extras preference is on; `isInspectable` covers Safari only.
            let preferences = webView.configuration.preferences
            if preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) {
                preferences.setValue(true, forKey: "developerExtrasEnabled")
            }
            // The inspector docks beside the web view, inside the web view's
            // superview, which is the page area. WebKit sizes both views.
            guard call(inspector, "show"), call(inspector, "attach") else { return false }
            FileHandle.standardError.write(Data("INSPECTDEBUG shown visible=\(inspector.value(forKey: "visible") ?? "?") superview=\(String(describing: webView.superview?.subviews.map { type(of: $0) }))\n".utf8))
            docked.insert(id)
        }
        return true
    }

    private static func inspector(of webView: WKWebView) -> NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func call(_ object: NSObject, _ name: String) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        object.perform(selector)
        return true
    }
}
