import Foundation
import WebKit
import chord_logic

/// Reads and acts on the page in a web view for page actions. Its scripts
/// run in their own content world, so the page's scripts cannot see or change
/// them; they share the page's DOM, which is how clicks and typing reach it.
@MainActor
final class WebPageDriver: PageDriver {
    static let contentWorld = WKContentWorld.world(name: "ChordAgent")

    struct DriverError: LocalizedError {
        var errorDescription: String?
    }

    private let webView: WKWebView
    /// The most page text a snapshot includes. The Apple model has a small
    /// context, so it gets less.
    private let maximumText: Int

    init(webView: WKWebView, maximumText: Int) {
        self.webView = webView
        self.maximumText = maximumText
    }

    func snapshot() async throws -> PageSnapshot {
        let json = try await run(Self.snapshotScript, arguments: ["maxText": maximumText])
        guard let snapshot = try? JSONDecoder().decode(PageSnapshot.self, from: Data(json.utf8)) else {
            throw DriverError(errorDescription: "The page could not be read.")
        }
        return snapshot
    }

    func perform(_ action: PageAction) async throws {
        switch action {
        case .click(let id):
            try await expectOK(run(Self.clickScript, arguments: ["id": String(id)]))
        case .type(let id, let text, let submit):
            try await expectOK(run(Self.typeScript, arguments: ["id": String(id), "text": text, "submit": submit]))
        case .navigate(let url):
            webView.load(URLRequest(url: url))
        case .scroll(let down):
            _ = try await run("window.scrollBy(0, (down ? 1 : -1) * window.innerHeight * 0.8); return 'ok';",
                              arguments: ["down": down])
        case .finish:
            return
        }
        await settle()
    }

    /// Waits for the page to react: a moment for scripts, then up to ten
    /// seconds for any navigation the step started.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(700))
        var waited = 0
        while webView.isLoading && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    private func expectOK(_ result: String) throws {
        guard result == "ok" else { throw DriverError(errorDescription: result) }
    }

    /// Runs `body` as an async function in the agent's content world and
    /// returns the string it returns.
    private func run(_ body: String, arguments: [String: Any]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: Self.contentWorld) { result in
                switch result {
                case .success(let value):
                    continuation.resume(returning: (value as? String) ?? "")
                case .failure(let error):
                    continuation.resume(throwing: DriverError(errorDescription: error.localizedDescription))
                }
            }
        }
    }

    // MARK: Scripts

    /// Numbers the visible interactive elements with `data-chord-agent` and
    /// returns the page as JSON in the shape of `PageSnapshot`.
    static let snapshotScript = """
        document.querySelectorAll('[data-chord-agent]').forEach(e => e.removeAttribute('data-chord-agent'));
        const selector = 'a[href], button, input:not([type=hidden]), textarea, select, [role=button], [role=link], [role=tab], [role=menuitem], [contenteditable=true]';
        const elements = [];
        let id = 0;
        for (const el of document.querySelectorAll(selector)) {
          const box = el.getBoundingClientRect();
          if (box.width < 1 || box.height < 1) continue;
          const style = getComputedStyle(el);
          if (style.visibility === 'hidden' || style.display === 'none') continue;
          if (box.bottom < -window.innerHeight || box.top > window.innerHeight * 2) continue;
          id += 1;
          el.setAttribute('data-chord-agent', String(id));
          const tag = el.tagName.toLowerCase();
          const type = (el.getAttribute('type') || '').toLowerCase();
          let role = el.getAttribute('role');
          if (!role) {
            if (tag === 'a') role = 'link';
            else if (tag === 'button' || ['submit', 'button', 'reset'].includes(type)) role = 'button';
            else if (tag === 'select') role = 'select';
            else if (type === 'checkbox' || type === 'radio') role = type;
            else role = 'textbox';
          }
          const label = (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.name || '')
            .trim().replace(/\\s+/g, ' ').slice(0, 80);
          const submits = (tag === 'button' && el.form && (type === '' || type === 'submit')) || (tag === 'input' && type === 'submit');
          elements.push({ id, role, label, href: tag === 'a' ? el.href : null, submits: !!submits });
          if (id >= 80) break;
        }
        const text = (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, maxText);
        return JSON.stringify({ url: location.href, title: document.title, text, elements });
        """

    static let clickScript = """
        const el = document.querySelector(`[data-chord-agent="${id}"]`);
        if (!el) return 'Element ' + id + ' is no longer on the page.';
        el.scrollIntoView({ block: 'center' });
        el.click();
        return 'ok';
        """

    /// Sets a field's value through the element's own setter, so frameworks
    /// that watch input events see the change.
    static let typeScript = """
        const el = document.querySelector(`[data-chord-agent="${id}"]`);
        if (!el) return 'Element ' + id + ' is no longer on the page.';
        el.scrollIntoView({ block: 'center' });
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
        } else {
          const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value')?.set;
          if (setter) setter.call(el, text); else el.value = text;
        }
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        if (submit) {
          if (el.form && el.form.requestSubmit) el.form.requestSubmit();
          else el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
        }
        return 'ok';
        """
}
