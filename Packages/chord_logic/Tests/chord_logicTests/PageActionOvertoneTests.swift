import Foundation
import Testing
@testable import chord_logic

/// An overtone workspace stand-in that keeps files in memory.
/// Contract, matching `OvertoneWorkspace`: `context` returns `files`;
/// `write` replaces or deletes a file, or throws `failure` when set.
@MainActor
final class FakeOvertoneWorkspace: OvertoneWorkspace {
    var files: [OvertoneContext.File] = []
    var writes: [(String, String)] = []
    var failure: Error?

    func context() -> OvertoneContext {
        OvertoneContext(folderName: "shop.example", files: files)
    }

    func write(file: String, content: String) async throws {
        if let failure { throw failure }
        writes.append((file, content))
        files.removeAll { $0.name == file }
        if !content.isEmpty { files.append(.init(name: file, content: content)) }
    }
}

private let page = PageSnapshot(url: "https://shop.example/", title: "Shop", text: "Welcome", elements: [
    PageElement(id: 1, role: "link", label: "Home", href: "https://shop.example/"),
], outline: "body\n  main#content.grid")

private func writeReply(_ file: String, _ content: String) -> Result<AgentDecisionPayload, AgentModelError> {
    .success(AgentDecisionPayload(thought: "restyle", action: "write_overtone", file: file, content: content))
}

struct OvertonePayloadTests {
    @Test func readsAWrite() {
        let payload = AgentDecisionPayload(thought: "", action: "write_overtone", file: "style.css", content: "a {}")
        #expect(payload.pageAction == .writeOvertone(file: "style.css", content: "a {}"))
    }

    @Test func aWriteWithoutContentDeletes() {
        let payload = AgentDecisionPayload(thought: "", action: "write_overtone", file: "style.css")
        #expect(payload.pageAction == .writeOvertone(file: "style.css", content: ""))
    }

    @Test(arguments: [nil, "../evil.js", "style.txt", ".hidden.css", "a/b.css", "two.dots.css", "", "émoji.css"])
    func badFileNamesAreRejected(file: String?) {
        #expect(AgentDecisionPayload(thought: "", action: "write_overtone", file: file, content: "x").pageAction == nil)
    }

    @Test(arguments: ["style.css", "main.js", "panel.html", "Dark_Mode-2.CSS"])
    func plainFileNamesAreAccepted(file: String) {
        #expect(OvertoneFiles.isValidName(file))
    }

    @Test func writesAlwaysNeedApproval() {
        #expect(AgentSafety.needsConfirmation(.writeOvertone(file: "style.css", content: "a {}"), on: page))
    }

    @MainActor @Test func summariesNameTheFile() {
        #expect(AgentRunner.summarize(.writeOvertone(file: "style.css", content: "a {}"), on: page)
                == "Write overtone file style.css")
        #expect(AgentRunner.summarize(.writeOvertone(file: "style.css", content: ""), on: page)
                == "Delete overtone file style.css")
    }
}

struct AgentPromptTests {
    @Test func thePromptStartsWithThePage() {
        let prompt = AgentInstructions.prompt(task: "Hide ads", history: [], page: page)
        #expect(prompt.hasPrefix("Current page:\nURL: https://shop.example/"))
        let pageIndex = prompt.range(of: "Current page:")!.lowerBound
        let taskIndex = prompt.range(of: "Task: Hide ads")!.lowerBound
        #expect(pageIndex < taskIndex)
    }

    @Test func thePromptIncludesTheOutline() {
        #expect(AgentInstructions.prompt(task: "t", history: [], page: page).contains("Outline:\nbody\n  main#content.grid"))
    }

    @Test func aSnapshotWithoutAnOutlineLeavesItOut() {
        let bare = PageSnapshot(url: "https://a.example", title: "", text: "", elements: [])
        #expect(!bare.promptText.contains("Outline:"))
    }

    @Test func thePromptShowsTheOvertoneFiles() {
        let overtone = OvertoneContext(folderName: "shop.example", files: [.init(name: "style.css", content: "a { color: red }")])
        let prompt = AgentInstructions.prompt(task: "t", history: [], page: page, overtone: overtone)
        #expect(prompt.contains("Overtone for this domain (shop.example):\n--- style.css\na { color: red }"))
    }

    @Test func anEmptyOvertoneSaysSo() {
        #expect(OvertoneContext(folderName: "a.example", files: []).promptText == "No files yet.")
    }

    @Test func longFilesAreShortened() {
        let long = String(repeating: "x", count: OvertoneFiles.maximumPromptCharacters * 2)
        let text = OvertoneContext(folderName: "a.example", files: [.init(name: "a.css", content: long)]).promptText
        #expect(text.hasSuffix("… (shortened)"))
        #expect(text.count < long.count)
    }
}

@MainActor
struct OvertoneRunnerTests {
    @Test func anApprovedWriteGoesToTheWorkspace() async {
        let model = ScriptedModel([writeReply("style.css", "main { gap: 0 }"), .success(.init(thought: "", action: "finish", answer: "Done"))])
        let driver = FakeDriver(page: page)
        let workspace = FakeOvertoneWorkspace()
        var asked: [PageAction] = []
        let outcome = await AgentRunner().run(task: "t", model: model, driver: driver, overtones: workspace,
                                              confirm: { action, _ in asked.append(action); return true },
                                              onStep: { _ in })
        #expect(outcome == .finished(answer: "Done"))
        #expect(asked == [.writeOvertone(file: "style.css", content: "main { gap: 0 }")])
        #expect(workspace.writes.map(\.0) == ["style.css"])
        #expect(driver.performed.isEmpty)
        // The next prompt shows the file the model wrote.
        #expect(model.prompts.last?.contains("--- style.css\nmain { gap: 0 }") == true)
    }

    @Test func aDeclinedWriteWritesNothing() async {
        let model = ScriptedModel([writeReply("style.css", "a {}")])
        let workspace = FakeOvertoneWorkspace()
        let outcome = await AgentRunner().run(task: "t", model: model, driver: FakeDriver(page: page), overtones: workspace,
                                              confirm: { _, _ in false }, onStep: { _ in })
        #expect(outcome == .declined)
        #expect(workspace.writes.isEmpty)
    }

    @Test func withoutAWorkspaceAWriteIsAnInvalidStep() async {
        let model = ScriptedModel([writeReply("style.css", "a {}")])
        var steps: [AgentStep] = []
        _ = await AgentRunner().run(task: "t", model: model, driver: FakeDriver(page: page),
                                    confirm: { _, _ in Issue.record("No approval expected"); return true },
                                    onStep: { steps.append($0) })
        #expect(steps.first?.summary == "Invalid step (write_overtone); try again")
    }

    @Test func anOversizedWriteIsAnInvalidStep() async {
        let big = String(repeating: "a", count: OvertoneFiles.maximumFileBytes + 1)
        let model = ScriptedModel([writeReply("style.css", big)])
        let workspace = FakeOvertoneWorkspace()
        var steps: [AgentStep] = []
        _ = await AgentRunner().run(task: "t", model: model, driver: FakeDriver(page: page), overtones: workspace,
                                    confirm: { _, _ in Issue.record("No approval expected"); return true },
                                    onStep: { steps.append($0) })
        #expect(steps.first?.summary.hasPrefix("Invalid step") == true)
        #expect(workspace.writes.isEmpty)
    }

    @Test func aFailedWriteFailsTheRun() async {
        struct DiskFull: LocalizedError { var errorDescription: String? { "disk full" } }
        let model = ScriptedModel([writeReply("style.css", "a {}")])
        let workspace = FakeOvertoneWorkspace()
        workspace.failure = DiskFull()
        let outcome = await AgentRunner().run(task: "t", model: model, driver: FakeDriver(page: page), overtones: workspace,
                                              confirm: { _, _ in true }, onStep: { _ in })
        #expect(outcome == .failed("Could not Write overtone file style.css: disk full"))
    }
}

struct OvertoneFilesTests {
    let folder: URL

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "chord-overtone-files-\(UUID().uuidString)")
    }

    @Test func writesReadsAndDeletes() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try OvertoneFiles.write("style.css", content: "a {}", in: folder)
        try OvertoneFiles.write("main.js", content: "run()", in: folder)
        #expect(OvertoneFiles.read(folder) == [.init(name: "main.js", content: "run()"), .init(name: "style.css", content: "a {}")])

        try OvertoneFiles.write("style.css", content: "b {}", in: folder)
        #expect(OvertoneFiles.read(folder).last == .init(name: "style.css", content: "b {}"))

        try OvertoneFiles.write("style.css", content: "", in: folder)
        try OvertoneFiles.write("main.js", content: "", in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func deletingAMissingFileIsFine() throws {
        try OvertoneFiles.write("style.css", content: "", in: folder)
    }

    @Test func refusesBadNamesAndLargeFiles() {
        #expect(throws: OvertoneFiles.WriteError.invalidName("../x.css")) {
            try OvertoneFiles.write("../x.css", content: "a", in: folder)
        }
        #expect(throws: OvertoneFiles.WriteError.tooLarge) {
            try OvertoneFiles.write("x.css", content: String(repeating: "a", count: OvertoneFiles.maximumFileBytes + 1), in: folder)
        }
    }

    @Test func readIgnoresOtherFiles() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "notes".write(to: folder.appending(path: "readme.md"), atomically: true, encoding: .utf8)
        #expect(OvertoneFiles.read(folder).isEmpty)
    }

    @Test func theFolderIsTheSuggestedDomain() {
        #expect(OvertoneFiles.folderName(for: URL(string: "https://gist.github.com/x")!, existing: []) == "github.com")
        #expect(OvertoneFiles.folderName(for: URL(string: "https://www.bbc.co.uk/news")!, existing: []) == "bbc.co.uk")
        #expect(OvertoneFiles.folderName(for: URL(string: "about:blank")!, existing: []) == nil)
    }

    @Test func anExistingDomainOvertoneWinsTheMostSpecificFirst() {
        let existing = [Overtone(id: "github.com", domain: "github.com"),
                        Overtone(id: "gist.github.com", domain: "gist.github.com"),
                        Overtone(id: "dark-mode", domain: nil)]
        #expect(OvertoneFiles.folderName(for: URL(string: "https://gist.github.com/x")!, existing: existing) == "gist.github.com")
        #expect(OvertoneFiles.folderName(for: URL(string: "https://github.com/x")!, existing: existing) == "github.com")
    }
}

struct PageActionPaletteTests {
    let engine = SearchEngine.duckDuckGo
    let previous = ["count the completed tasks", "hide the sidebar", "make the header sticky"]

    @Test func aDollarSignStartsATask() {
        #expect(PaletteResults.pageActionTask(in: "$count tasks") == "count tasks")
        #expect(PaletteResults.pageActionTask(in: "  $  count tasks ") == "count tasks")
        #expect(PaletteResults.pageActionTask(in: "$") == "")
        #expect(PaletteResults.pageActionTask(in: "count $5") == nil)
    }

    @Test func onlyADollarSignListsRecentTasks() {
        let items = PaletteResults.build(query: "$", tabs: [], commands: [], history: [], pageActions: previous, engine: engine)
        #expect(items == previous.map { .pageAction(task: $0, previous: true) })
    }

    @Test func typedTextComesFirstThenMatchingTasks() {
        let items = PaletteResults.build(query: "$hide", tabs: [], commands: [], history: [], pageActions: previous, engine: engine)
        #expect(items == [.pageAction(task: "hide", previous: false), .pageAction(task: "hide the sidebar", previous: true)])
    }

    @Test func theSameTaskIsNotListedTwice() {
        let items = PaletteResults.pageActionRows(task: "Hide the sidebar", previous: previous)
        #expect(items == [.pageAction(task: "Hide the sidebar", previous: false)])
    }

    @Test func equalMatchesKeepTheMostRecentFirst() {
        let items = PaletteResults.pageActionRows(task: "the", previous: ["the b", "the a"])
        #expect(items.dropFirst() == [.pageAction(task: "the b", previous: true), .pageAction(task: "the a", previous: true)])
    }

    @Test func theListIsCapped() {
        let many = (1...20).map { "task \($0)" }
        #expect(PaletteResults.pageActionRows(task: "", previous: many).count == PaletteResults.maximumPageActions)
        #expect(PaletteResults.pageActionRows(task: "task", previous: many).count == PaletteResults.maximumPageActions)
    }

    @Test func withoutAPageDollarTextIsSearched() {
        let items = PaletteResults.build(query: "$5 coffee", tabs: [], commands: [], history: [], engine: engine)
        guard case .search(let query, _, _) = items.first else {
            Issue.record("Expected a search row, got \(items)")
            return
        }
        #expect(query == "$5 coffee")
    }
}

struct AgentTaskHistoryTests {
    @Test func recordsTasksMostRecentFirstWithoutRepeats() throws {
        let database = try ChordDatabase.inMemory()
        try database.recordAgentTask("first", at: Date(timeIntervalSince1970: 1))
        try database.recordAgentTask("second", at: Date(timeIntervalSince1970: 2))
        try database.recordAgentTask("  first ", at: Date(timeIntervalSince1970: 3))
        try database.recordAgentTask("   ", at: Date(timeIntervalSince1970: 4))
        #expect(try database.recentAgentTasks() == ["first", "second"])
        #expect(try database.recentAgentTasks(limit: 1) == ["first"])
    }

    @Test func oldTasksAreRemoved() throws {
        let database = try ChordDatabase.inMemory()
        for index in 0...ChordDatabase.maximumAgentTasks {
            try database.recordAgentTask("task \(index)", at: Date(timeIntervalSince1970: Double(index)))
        }
        let kept = try database.recentAgentTasks(limit: 1000)
        #expect(kept.count == ChordDatabase.maximumAgentTasks)
        #expect(!kept.contains("task 0"))
    }
}
