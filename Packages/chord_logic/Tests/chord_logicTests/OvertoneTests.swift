import Foundation
import Testing
@testable import chord_logic

struct OvertoneLibraryTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "chord-overtones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to path: String) throws {
        let file = folder.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    @Test func aMissingFolderGivesNothing() {
        #expect(OvertoneLibrary.load(from: folder.appending(path: "missing")).isEmpty)
    }

    @Test func readsFilesByTypeInNameOrder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("b {}", to: "github.com/2.css")
        try write("a {}", to: "github.com/1.css")
        try write("run()", to: "github.com/main.js")
        try write("<p>hi</p>", to: "github.com/note.html")
        try write("ignored", to: "github.com/readme.md")
        try write("hidden", to: "github.com/.secret.js")

        let overtones = OvertoneLibrary.load(from: folder)
        #expect(overtones == [Overtone(id: "github.com", domain: "github.com", styles: ["a {}", "b {}"],
                                       scripts: ["run()"], html: ["<p>hi</p>"])])
    }

    @Test func folderNamesDecideTheDomain() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write("x", to: "Wide Layout/a.css")
        try write("x", to: "App.DataDogHQ.com/a.css")
        try write("x", to: ".hidden/a.css")
        try write("x", to: "loose-file.css")

        let overtones = OvertoneLibrary.load(from: folder)
        #expect(overtones.map(\.id) == ["App.DataDogHQ.com", "Wide Layout"])
        #expect(overtones.map(\.domain) == ["app.datadoghq.com", nil])
    }

    @Test func domainOvertonesApplyToSubdomains() {
        let overtone = Overtone(id: "github.com", domain: "github.com")
        #expect(overtone.appliesByDomain(to: URL(string: "https://gist.github.com/x")!))
        #expect(!overtone.appliesByDomain(to: URL(string: "https://gitlab.com")!))
        #expect(!Overtone(id: "Wide", domain: nil).appliesByDomain(to: URL(string: "https://github.com")!))
    }

    @Test func applicableJoinsDomainAndRuleOvertonesWithoutRepeats() {
        let byDomain = Overtone(id: "github.com", domain: "github.com")
        let wide = Overtone(id: "Wide", domain: nil)
        let quiet = Overtone(id: "Quiet", domain: nil)
        let result = OvertoneLibrary.applicable(
            to: URL(string: "https://github.com")!, overtones: [byDomain, wide, quiet],
            ruleOvertoneIDs: ["Wide", "github.com", "Missing"])
        #expect(result.map(\.id) == ["github.com", "Wide"])
    }
}

struct OvertoneScriptTests {
    @Test func noFilesGiveNoScripts() {
        let empty = Overtone(id: "x", domain: nil)
        #expect(OvertoneScript.styles(for: empty) == nil)
        #expect(OvertoneScript.body(for: empty) == nil)
    }

    @Test func textIsEmbeddedSafely() throws {
        let tricky = "a\" ); alert(1); (\"\n</script>"
        let script = try #require(OvertoneScript.styles(for: Overtone(id: "x", domain: nil, styles: [tricky])))
        #expect(script.contains(OvertoneScript.literal(tricky)))
        #expect(!script.contains("\n</script>"))
    }

    @Test func literalsAreJSONStrings() throws {
        let literal = OvertoneScript.literal("line\n\"quoted\"")
        let decoded = try JSONDecoder().decode(String.self, from: Data(literal.utf8))
        #expect(decoded == "line\n\"quoted\"")
    }

    @Test func bodyAddsHTMLBeforeScripts() throws {
        let overtone = Overtone(id: "x", domain: nil, scripts: ["first()", "second()"], html: ["<b>hi</b>"])
        let script = try #require(OvertoneScript.body(for: overtone))
        let html = try #require(script.range(of: "innerHTML"))
        let first = try #require(script.range(of: "first()"))
        let second = try #require(script.range(of: "second()"))
        #expect(html.lowerBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound)
    }

    @Test func scriptsWithoutHTMLSkipTheHolder() throws {
        let script = try #require(OvertoneScript.body(for: Overtone(id: "x", domain: nil, scripts: ["go()"])))
        #expect(!script.contains("innerHTML"))
    }
}
