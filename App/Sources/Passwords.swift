import AppKit
import OSLog
import SwiftUI
import WebKit
import chord_logic

/// Runs a command-line tool with `Process`, without a shell.
///
/// Contract: see `CommandRunner`. Standard input is empty. Standard output and
/// standard error are read while the tool runs, so a tool with a lot of output
/// cannot block on a full pipe.
struct ProcessRunner: CommandRunner {
    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let collected = Collected()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    collected.output = output.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    collected.errors = errors.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus, output: collected.output,
                    errorOutput: String(data: collected.errors, encoding: .utf8) ?? ""))
            }
        }
    }

    /// The two outputs, each written by one reader before the group finishes.
    private final class Collected: @unchecked Sendable {
        var output = Data()
        var errors = Data()
    }
}

/// The connection to 1Password through its command-line tool. `service` is nil
/// when the tool is not installed.
@MainActor
@Observable
final class Passwords {
    static let log = Logger(subsystem: "net.asymptomatic.Chord", category: "passwords")

    private(set) var service: (any PasswordService)?

    init() {
        refresh()
    }

    /// Looks for the tool again, for example after the user installs it.
    func refresh() {
        // `--args -ChordOnePasswordCLI /path/to/op` uses that tool, for testing
        // against a stub.
        let executable = UserDefaults.standard.string(forKey: "ChordOnePasswordCLI").map { URL(filePath: $0) }
            ?? OnePasswordCLI.find()
        service = executable.map { OnePasswordCLI(executable: $0, runner: ProcessRunner()) }
    }
}

/// Fills a login into the page in a web view. The script runs in its own
/// content world, so the page's scripts cannot see or change it.
@MainActor
enum LoginFiller {
    static let contentWorld = WKContentWorld.world(name: "ChordPasswords")

    enum Result: Equatable {
        case filled
        /// The page has no visible username or password field.
        case noFields
        /// The page is no longer on the host the login was chosen for.
        case pageMoved
    }

    /// Fills `credential` into the main frame of `webView`, only while the page
    /// is still on `expectedHost`. The secrets are passed as script arguments,
    /// never written into the script's text.
    static func fill(_ credential: LoginCredential, expectedHost: String, in webView: WKWebView) async throws -> Result {
        let arguments: [String: Any] = [
            "expectedHost": expectedHost,
            "username": credential.username ?? "",
            "password": credential.password ?? "",
        ]
        let value = try await webView.callAsyncJavaScript(fillScript, arguments: arguments, in: nil, in: contentWorld)
        switch value as? String {
        case "filled": return .filled
        case "moved": return .pageMoved
        default: return .noFields
        }
    }

    /// Finds the visible password field and the username field before it in
    /// the same form. A page that asks only for a username, the first step of
    /// many sign-in pages, gets the username alone. Each value is set with the
    /// input element's own setter and announced with input and change events,
    /// so pages built with frameworks such as React see it.
    static let fillScript = """
        if (location.hostname !== expectedHost) return 'moved';
        const usable = el => {
          const box = el.getBoundingClientRect();
          if (box.width < 1 || box.height < 1) return false;
          const style = getComputedStyle(el);
          return style.visibility !== 'hidden' && style.display !== 'none' && !el.disabled && !el.readOnly;
        };
        const inputs = Array.from(document.querySelectorAll('input')).filter(usable);
        const textTypes = ['text', 'email', 'tel', ''];
        const named = el => /user|login|email|account/i.test((el.name || '') + ' ' + (el.id || '') + ' ' + (el.autocomplete || ''));
        const passwords = inputs.filter(el => el.type === 'password');
        const passwordField = passwords.find(el => el.autocomplete !== 'new-password') || passwords[0] || null;
        let userField = null;
        if (passwordField) {
          const scope = passwordField.form
            ? inputs.filter(el => el.form === passwordField.form)
            : inputs;
          const before = scope.slice(0, scope.indexOf(passwordField)).filter(el => textTypes.includes(el.type));
          userField = before.find(el => /username|email/.test(el.autocomplete || '')) || before[before.length - 1] || null;
        } else {
          const candidates = inputs.filter(el => textTypes.includes(el.type));
          userField = candidates.find(el => /username|email/.test(el.autocomplete || ''))
            || candidates.find(el => el.type === 'email') || candidates.find(named) || null;
        }
        const setValue = (el, value) => {
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          setter.call(el, value);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        let filled = false;
        if (userField && username) { setValue(userField, username); filled = true; }
        if (passwordField && password) { setValue(passwordField, password); filled = true; }
        if (passwordField) passwordField.focus();
        return filled ? 'filled' : 'none';
        """
}

/// The sheet that explains how to connect Chord to 1Password.
struct OnePasswordSetupView: View {
    let passwords: Passwords
    /// Called with true when 1Password answered.
    let onDone: (Bool) -> Void
    @State private var checking = false
    @State private var problem: String?

    static let installCommand = "brew install 1password-cli"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect 1Password").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Chord fills logins through the 1Password command-line tool, which unlocks with the 1Password app.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            step(1, "Install the 1Password command-line tool.") {
                HStack(spacing: 8) {
                    Text(Self.installCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(0.06)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            step(2, "In 1Password, open Settings > Developer and turn on Integrate with 1Password CLI.") { EmptyView() }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { onDone(false) }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(checking ? "Checking…" : "Check Again", action: check)
                    .buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(checking)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func step<Extra: View>(_ number: Int, _ text: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Circle().fill(.primary.opacity(0.08)))
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.system(size: 13))
                extra()
            }
        }
    }

    private func check() {
        passwords.refresh()
        guard let service = passwords.service else {
            problem = "Chord did not find the op tool in /opt/homebrew/bin or /usr/local/bin."
            return
        }
        checking = true
        problem = nil
        Task {
            do {
                try await service.verify()
                onDone(true)
            } catch PasswordServiceError.notSignedIn {
                problem = "1Password did not answer. Check that the CLI integration is on and the app is running."
            } catch PasswordServiceError.cancelled {
                problem = "1Password was not unlocked."
            } catch {
                problem = "1Password could not be reached: \(error.localizedDescription)"
            }
            checking = false
        }
    }
}
