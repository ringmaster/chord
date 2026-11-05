import Foundation

/// A login saved in a password manager, without its secrets.
public struct LoginItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The username, when the password manager lists it.
    public var username: String?
    /// The vault or folder the login is in.
    public var vault: String?
    /// The website addresses saved with the login.
    public var urls: [String]

    public init(id: String, title: String, username: String?, vault: String?, urls: [String]) {
        self.id = id
        self.title = title
        self.username = username
        self.vault = vault
        self.urls = urls
    }
}

/// A login's secrets, read only when the user fills a page.
public struct LoginCredential: Equatable, Sendable {
    public var username: String?
    public var password: String?

    public init(username: String?, password: String?) {
        self.username = username
        self.password = password
    }
}

public enum PasswordServiceError: Error, Equatable {
    /// The password manager's command-line tool is not installed.
    case notInstalled
    /// The tool is installed but cannot reach an unlocked account, for example
    /// because its integration with the desktop app is off.
    case notSignedIn
    /// The user dismissed the password manager's unlock prompt.
    case cancelled
    /// The tool failed with this message.
    case failed(String)
    /// The tool's output was not in the expected shape.
    case unreadableResponse
}

/// The contract Chord needs from a password manager. Only the module that
/// implements it changes when the password manager changes.
///
/// - Every method throws `PasswordServiceError` and nothing else.
/// - No method retries. A caller that wants a retry calls again.
/// - A method may wait while the password manager asks the user to unlock it.
public protocol PasswordService: Sendable {
    /// Checks that the password manager can be reached and is unlocked.
    func verify() async throws
    /// The logins whose saved addresses match `page`, sorted by title.
    func logins(matching page: URL) async throws -> [LoginItem]
    /// The username and password of `login`.
    func credential(for login: LoginItem) async throws -> LoginCredential
}

/// Decides which saved logins belong to a page, and which pages may be filled.
public enum LoginMatching {
    /// True when Chord may fill a login into `page`: an https page, or an http
    /// page on this Mac. A login is never filled into a page that is sent
    /// unencrypted over the network.
    public static func canFill(_ page: URL) -> Bool {
        guard let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    /// True when the saved address `saved` belongs to `page`: the hosts are the
    /// same, or the page is on a subdomain of the saved host. A leading "www."
    /// is ignored on both. A saved address without a scheme is read as https.
    public static func matches(saved: String, page: URL) -> Bool {
        let text = saved.contains("://") ? saved : "https://" + saved
        guard let savedHost = URL(string: text)?.host()?.lowercased(),
              let pageHost = page.host()?.lowercased() else { return false }
        let a = withoutWWW(savedHost)
        let b = withoutWWW(pageHost)
        guard !a.isEmpty, a.contains(".") || a == "localhost" else { return false }
        return b == a || b.hasSuffix("." + a)
    }

    private static func withoutWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// The result of running a command.
public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: Data
    public var errorOutput: String

    public init(status: Int32, output: Data, errorOutput: String) {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// Runs a command-line tool. `Process` in the app; a test double in tests.
///
/// Contract: runs `executable` with `arguments` and no shell, waits for it to
/// quit, and returns its exit status, standard output, and standard error.
/// Throws only when the tool could not start.
public protocol CommandRunner: Sendable {
    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult
}

/// 1Password, through its command-line tool `op`.
/// See https://developer.1password.com/docs/cli/reference/.
///
/// `op` reaches the user's account through the 1Password app when the app's
/// setting "Integrate with 1Password CLI" is on. The app then asks the user to
/// unlock with Touch ID or the account password, so Chord never sees or stores
/// an account secret.
public struct OnePasswordCLI: PasswordService {
    /// Where the tool is installed by Homebrew on Apple silicon and on Intel,
    /// and by 1Password's installer package. Apps do not get the shell's PATH.
    public static let defaultLocations = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]

    public let executable: URL
    let runner: any CommandRunner

    public init(executable: URL, runner: any CommandRunner) {
        self.executable = executable
        self.runner = runner
    }

    /// The first of `locations` where an executable file exists, or nil.
    public static func find(in locations: [String] = defaultLocations,
                            isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        locations.first(where: isExecutable).map { URL(filePath: $0) }
    }

    public func verify() async throws {
        _ = try await runJSON(["vault", "list", "--format", "json"])
    }

    public func logins(matching page: URL) async throws -> [LoginItem] {
        let json = try await runJSON(["item", "list", "--categories", "Login", "--format", "json"])
        guard let entries = json as? [[String: Any]] else { throw PasswordServiceError.unreadableResponse }
        let items = entries.compactMap { entry -> LoginItem? in
            guard let id = entry["id"] as? String, let title = entry["title"] as? String else { return nil }
            let urls = (entry["urls"] as? [[String: Any]] ?? []).compactMap { $0["href"] as? String }
            let username = (entry["additional_information"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let vault = (entry["vault"] as? [String: Any])?["name"] as? String
            return LoginItem(id: id, title: title, username: username, vault: vault, urls: urls)
        }
        return items
            .filter { item in item.urls.contains { LoginMatching.matches(saved: $0, page: page) } }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func credential(for login: LoginItem) async throws -> LoginCredential {
        // The id is passed as an argument, never through a shell. It must still
        // not look like an option.
        guard Self.isValidID(login.id) else { throw PasswordServiceError.failed("The login has an invalid id.") }
        let json = try await runJSON(["item", "get", login.id, "--format", "json", "--reveal"])
        guard let item = json as? [String: Any], let fields = item["fields"] as? [[String: Any]] else {
            throw PasswordServiceError.unreadableResponse
        }
        func value(purpose: String) -> String? {
            fields.first { ($0["purpose"] as? String) == purpose }?["value"] as? String
        }
        return LoginCredential(username: value(purpose: "USERNAME"), password: value(purpose: "PASSWORD"))
    }

    /// True when `id` has the form of a 1Password item id: letters and digits only.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private func runJSON(_ arguments: [String]) async throws -> Any {
        let result: CommandResult
        do {
            result = try await runner.run(executable, arguments: arguments)
        } catch {
            throw PasswordServiceError.notInstalled
        }
        guard result.status == 0 else { throw Self.error(from: result.errorOutput) }
        guard let json = try? JSONSerialization.jsonObject(with: result.output) else {
            throw PasswordServiceError.unreadableResponse
        }
        return json
    }

    /// Reads `op`'s error message, such as
    /// "[ERROR] 2026/11/05 08:00:00 authorization prompt dismissed, please try again".
    static func error(from message: String) -> PasswordServiceError {
        let lower = message.lowercased()
        if lower.contains("dismissed") || lower.contains("cancel") {
            return .cancelled
        }
        if lower.contains("not signed in") || lower.contains("no accounts configured")
            || lower.contains("sign in") || lower.contains("connecting to desktop app")
            || lower.contains("cannot connect to 1password app") {
            return .notSignedIn
        }
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop the "[ERROR] date time " prefix.
        if text.hasPrefix("[ERROR]") {
            let parts = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            if parts.count == 4 { text = String(parts[3]) }
        }
        return .failed(text.isEmpty ? "1Password could not complete the request." : text)
    }
}
