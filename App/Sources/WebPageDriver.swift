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
    /// The most outline text a snapshot includes.
    private let maximumOutline: Int

    init(webView: WKWebView, maximumText: Int, maximumOutline: Int) {
        self.webView = webView
        self.maximumText = maximumText
        self.maximumOutline = maximumOutline
    }

    func snapshot() async throws -> PageSnapshot {
        let json = try await run(Self.snapshotScript, arguments: ["maxText": maximumText, "maxOutline": maximumOutline])
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
        case .finish, .writeOvertone:
            // The runner sends overtone writes to the overtone workspace.
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

        // An indented outline of the page's elements with ids and classes, for
        // writing CSS selectors. Runs of siblings that look the same are
        // shown once with a count, and the outline stops at maxOutline.
        const skip = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'LINK', 'META', 'BR', 'WBR']);
        const describe = (el) => {
          let line = el.tagName.toLowerCase();
          if (el.id) line += '#' + el.id;
          const classes = typeof el.className === 'string' ? el.className.trim().split(/\\s+/).filter(c => c).slice(0, 4) : [];
          if (classes.length) line += '.' + classes.join('.');
          const role = el.getAttribute('role');
          if (role) line += `[role=${role}]`;
          return line;
        };
        const lines = [];
        let size = 0;
        const walk = (el, depth) => {
          if (size > maxOutline || depth > 14) return;
          const kids = Array.from(el.children).filter(k => !skip.has(k.tagName));
          let index = 0;
          while (index < kids.length && size <= maxOutline) {
            const kid = kids[index];
            const signature = describe(kid);
            let run = 1;
            while (index + run < kids.length && describe(kids[index + run]) === signature) run += 1;
            if (kid.tagName === 'svg') {
              index += run;
              continue;
            }
            const own = Array.from(kid.childNodes).filter(n => n.nodeType === 3).map(n => n.textContent).join(' ')
              .trim().replace(/\\s+/g, ' ').slice(0, 40);
            const line = '  '.repeat(depth) + signature + (run > 1 ? ` ×${run}` : '') + (own ? ` "${own}"` : '');
            lines.push(line);
            size += line.length + 1;
            walk(kid, depth + 1);
            index += run;
          }
        };
        if (document.body) {
          lines.push(describe(document.body));
          walk(document.body, 1);
        }
        const outline = lines.join('\\n').slice(0, maxOutline);
        return JSON.stringify({ url: location.href, title: document.title, text, elements, outline });
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
