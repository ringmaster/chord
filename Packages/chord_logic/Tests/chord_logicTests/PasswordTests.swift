import Foundation
import Testing
@testable import chord_logic

/// A `CommandRunner` that records each call and answers with a fixed result.
///
/// Contract it stands in for: `run` starts the tool without a shell, waits for
/// it, and returns its status, standard output, and standard error; it throws
/// only when the tool could not start.
final class StubRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String]: CommandResult]
    private var fallback: CommandResult?
    private let failsToStart: Bool
    private(set) var calls: [[String]] = []

    init(answers: [[String]: CommandResult] = [:], fallback: CommandResult? = nil, failsToStart: Bool = false) {
        self.answers = answers
        self.fallback = fallback
        self.failsToStart = failsToStart
    }

    func run(_ executable: URL, arguments: [String]) async throws -> CommandResult {
        let answer = lock.withLock { () -> CommandResult? in
            calls.append(arguments)
            return answers[arguments] ?? fallback
        }
        if failsToStart { throw CocoaError(.fileNoSuchFile) }
        return answer ?? CommandResult(status: 1, output: Data(), errorOutput: "unexpected call")
    }
}

private func ok(_ json: String) -> CommandResult {
    CommandResult(status: 0, output: Data(json.utf8), errorOutput: "")
}

private func failure(_ message: String) -> CommandResult {
    CommandResult(status: 1, output: Data(), errorOutput: message)
}

private let listArguments = ["item", "list", "--categories", "Login", "--format", "json"]

private let listJSON = """
[
  {"id": "ghid0000000000000000000001", "title": "GitHub", "vault": {"id": "v1", "name": "Personal"},
   "additional_information": "owen", "urls": [{"primary": true, "href": "https://github.com/login"}]},
  {"id": "ghid0000000000000000000002", "title": "GitHub Work", "vault": {"id": "v2", "name": "Work"},
   "additional_information": "owen-work", "urls": [{"href": "github.com"}]},
  {"id": "exid0000000000000000000003", "title": "Example", "vault": {"id": "v1", "name": "Personal"},
   "additional_information": "", "urls": [{"href": "https://example.com"}]},
  {"id": "noid0000000000000000000004", "title": "No address", "vault": {"id": "v1", "name": "Personal"}}
]
"""

struct LoginMatchingTests {
    // Security: where logins may be filled, and which logins belong to a page.

    @Test(arguments: ["http://example.com/login", "ftp://example.com", "file:///Users/x/login.html",
                      "webkit-extension://abc/page.html", "about:blank", "http://192.168.1.5"])
    func insecureOrNonWebPagesAreNeverFilled(page: String) {
        #expect(!LoginMatching.canFill(URL(string: page)!))
    }

    @Test(arguments: ["https://example.com/login", "http://localhost:3000", "http://127.0.0.1/login"])
    func secureAndLocalPagesCanBeFilled(page: String) {
        #expect(LoginMatching.canFill(URL(string: page)!))
    }

    @Test func aLookAlikeHostDoesNotMatch() {
        let page = URL(string: "https://github.com.evil.example/login")!
        #expect(!LoginMatching.matches(saved: "https://github.com", page: page))
        #expect(!LoginMatching.matches(saved: "https://github.com", page: URL(string: "https://notgithub.com")!))
    }

    @Test func aParentDomainDoesNotMatchASubdomainLogin() {
        #expect(!LoginMatching.matches(saved: "https://accounts.example.com", page: URL(string: "https://example.com")!))
    }

    @Test func aBareTopLevelDomainNeverMatches() {
        #expect(!LoginMatching.matches(saved: "com", page: URL(string: "https://example.com")!))
        #expect(!LoginMatching.matches(saved: "", page: URL(string: "https://example.com")!))
    }

    @Test func theSameHostOrASubdomainMatches() {
        #expect(LoginMatching.matches(saved: "https://github.com/login", page: URL(string: "https://github.com/session")!))
        #expect(LoginMatching.matches(saved: "github.com", page: URL(string: "https://gist.github.com")!))
        #expect(LoginMatching.matches(saved: "https://www.example.com", page: URL(string: "https://example.com")!))
        #expect(LoginMatching.matches(saved: "https://example.com", page: URL(string: "https://WWW.Example.com")!))
    }
}

struct OnePasswordCLITests {
    let page = URL(string: "https://github.com/login")!

    private func service(_ runner: StubRunner) -> OnePasswordCLI {
        OnePasswordCLI(executable: URL(filePath: "/opt/homebrew/bin/op"), runner: runner)
    }

    // Security paths first.

    @Test func anIDThatLooksLikeAnOptionIsRefusedBeforeRunning() async {
        let runner = StubRunner(fallback: ok("{}"))
        let login = LoginItem(id: "--account=other", title: "X", username: nil, vault: nil, urls: [])
        await #expect(throws: PasswordServiceError.failed("The login has an invalid id.")) {
            try await service(runner).credential(for: login)
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func idsAreLettersAndDigitsOnly() {
        #expect(OnePasswordCLI.isValidID("ghid0000000000000000000001"))
        for id in ["", "a b", "a;b", "-x", "../x", String(repeating: "a", count: 65)] {
            #expect(!OnePasswordCLI.isValidID(id), "\(id)")
        }
    }

    @Test func aDismissedUnlockPromptIsCancelled() async {
        let runner = StubRunner(answers: [listArguments: failure("[ERROR] 2026/11/05 08:00:00 authorization prompt dismissed, please try again")])
        await #expect(throws: PasswordServiceError.cancelled) {
            try await service(runner).logins(matching: page)
        }
    }

    @Test func anAccountThatIsNotSignedInSaysSo() async {
        let runner = StubRunner(answers: [listArguments: failure("[ERROR] 2026/11/05 08:00:00 account is not signed in")])
        await #expect(throws: PasswordServiceError.notSignedIn) {
            try await service(runner).logins(matching: page)
        }
        #expect(OnePasswordCLI.error(from: "[ERROR] 2026/11/05 08:00:00 No accounts configured for use with 1Password CLI.") == .notSignedIn)
    }

    @Test func aToolThatCannotStartIsNotInstalled() async {
        await #expect(throws: PasswordServiceError.notInstalled) {
            try await service(StubRunner(failsToStart: true)).verify()
        }
    }

    @Test func otherErrorsKeepTheirMessageWithoutTheDate() {
        #expect(OnePasswordCLI.error(from: "[ERROR] 2026/11/05 08:00:00 \"xyz\" isn't an item") == .failed("\"xyz\" isn't an item"))
        #expect(OnePasswordCLI.error(from: "") == .failed("1Password could not complete the request."))
    }

    @Test func outputThatIsNotJSONIsUnreadable() async {
        let runner = StubRunner(answers: [listArguments: ok("not json")])
        await #expect(throws: PasswordServiceError.unreadableResponse) {
            try await service(runner).logins(matching: page)
        }
    }

    // Normal paths.

    @Test func loginsAreFilteredToThePageAndSortedByTitle() async throws {
        let runner = StubRunner(answers: [listArguments: ok(listJSON)])
        let logins = try await service(runner).logins(matching: page)
        #expect(logins.map(\.title) == ["GitHub", "GitHub Work"])
        #expect(logins.first?.username == "owen")
        #expect(logins.first?.vault == "Personal")
        #expect(runner.calls == [listArguments])
    }

    @Test func anEmptyUsernameIsNil() async throws {
        let runner = StubRunner(answers: [listArguments: ok(listJSON)])
        let logins = try await service(runner).logins(matching: URL(string: "https://example.com")!)
        #expect(logins.map(\.title) == ["Example"])
        #expect(logins.first?.username == nil)
    }

    @Test func theCredentialComesFromTheFieldPurposes() async throws {
        let id = "ghid0000000000000000000001"
        let item = """
        {"id": "\(id)", "title": "GitHub", "fields": [
          {"id": "notesPlain", "type": "STRING", "purpose": "NOTES", "label": "notes", "value": "hello"},
          {"id": "username", "type": "STRING", "purpose": "USERNAME", "label": "username", "value": "owen"},
          {"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "label": "password", "value": "p\\"a'ss"}
        ]}
        """
        let runner = StubRunner(answers: [["item", "get", id, "--format", "json", "--reveal"]: ok(item)])
        let login = LoginItem(id: id, title: "GitHub", username: "owen", vault: nil, urls: [])
        let credential = try await service(runner).credential(for: login)
        #expect(credential == LoginCredential(username: "owen", password: "p\"a'ss"))
    }

    @Test func verifyListsVaults() async throws {
        let runner = StubRunner(answers: [["vault", "list", "--format", "json"]: ok("[]")])
        try await service(runner).verify()
        #expect(runner.calls == [["vault", "list", "--format", "json"]])
    }

    @Test func theToolIsFoundInTheFirstLocationThatHasIt() {
        let found = OnePasswordCLI.find(in: ["/a/op", "/b/op", "/c/op"], isExecutable: { $0 != "/a/op" })
        #expect(found?.path == "/b/op")
        #expect(OnePasswordCLI.find(in: ["/a/op"], isExecutable: { _ in false }) == nil)
    }
}

struct LoginPaletteTests {
    let logins = [
        LoginItem(id: "a", title: "GitHub", username: "owen", vault: "Personal", urls: []),
        LoginItem(id: "b", title: "GitHub Work", username: "owen-work", vault: "Work", urls: []),
    ]

    @Test func withNothingTypedEveryLoginIsListedInOrder() {
        #expect(PaletteResults.logins(query: "", logins: logins) == logins.map(PaletteItem.login))
    }

    @Test func typingMatchesTitleUsernameOrVault() {
        #expect(PaletteResults.logins(query: "work", logins: logins) == [.login(logins[1])])
        #expect(PaletteResults.logins(query: "owen-w", logins: logins) == [.login(logins[1])])
        #expect(PaletteResults.logins(query: "zzz", logins: logins).isEmpty)
    }
}
