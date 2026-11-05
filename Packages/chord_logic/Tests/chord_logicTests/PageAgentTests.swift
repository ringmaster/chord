import Foundation
import Testing
@testable import chord_logic

/// A model stand-in that returns scripted replies in order, then "finish".
/// Contract, matching `PageAgentModel`: one payload per call, or the scripted error.
final class ScriptedModel: PageAgentModel, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<AgentDecisionPayload, AgentModelError>]
    private(set) var prompts: [String] = []
    let name = "scripted"

    init(_ replies: [Result<AgentDecisionPayload, AgentModelError>]) {
        self.replies = replies
    }

    func decide(system: String, prompt: String) async throws -> AgentDecisionPayload {
        let next: Result<AgentDecisionPayload, AgentModelError> = lock.withLock {
            prompts.append(prompt)
            return replies.isEmpty ? .success(.init(thought: "done", action: "finish", answer: "done")) : replies.removeFirst()
        }
        return try next.get()
    }
}

/// A page stand-in with a fixed snapshot that records each action.
/// Contract, matching `PageDriver`: `snapshot` returns `page`; `perform`
/// records the action, or throws `failure` when set.
@MainActor
final class FakeDriver: PageDriver {
    var page: PageSnapshot
    var performed: [PageAction] = []
    var failure: Error?
    var snapshotFailure: Error?

    init(page: PageSnapshot) {
        self.page = page
    }

    func snapshot() async throws -> PageSnapshot {
        if let snapshotFailure { throw snapshotFailure }
        return page
    }

    func perform(_ action: PageAction) async throws {
        if let failure { throw failure }
        performed.append(action)
    }
}

private let page = PageSnapshot(url: "https://shop.example/cart", title: "Cart", text: "Your cart", elements: [
    PageElement(id: 1, role: "link", label: "Home", href: "https://shop.example/"),
    PageElement(id: 2, role: "textbox", label: "Search"),
    PageElement(id: 3, role: "button", label: "Place order"),
    PageElement(id: 4, role: "button", label: "Sign in", submits: true),
])

private func reply(_ action: String, id: Int? = nil, text: String? = nil, url: String? = nil,
                   submit: Bool? = nil, answer: String? = nil) -> Result<AgentDecisionPayload, AgentModelError> {
    .success(AgentDecisionPayload(thought: "because", action: action, elementID: id, text: text, url: url,
                                  submit: submit, answer: answer))
}

struct AgentPayloadTests {
    @Test func readsEachAction() {
        #expect(AgentDecisionPayload(thought: "", action: "click", elementID: 2).pageAction == .click(elementID: 2))
        #expect(AgentDecisionPayload(thought: "", action: "TYPE", elementID: 2, text: "hi", submit: true).pageAction
                == .type(elementID: 2, text: "hi", submit: true))
        #expect(AgentDecisionPayload(thought: "", action: "type", elementID: 2, text: "hi").pageAction
                == .type(elementID: 2, text: "hi", submit: false))
        #expect(AgentDecisionPayload(thought: "", action: "navigate", url: "https://a.example").pageAction
                == .navigate(URL(string: "https://a.example")!))
        #expect(AgentDecisionPayload(thought: "", action: "scroll_down").pageAction == .scroll(down: true))
        #expect(AgentDecisionPayload(thought: "", action: "scroll_up").pageAction == .scroll(down: false))
        #expect(AgentDecisionPayload(thought: "t", action: "finish").pageAction == .finish(answer: "t"))
    }

    @Test func rejectsIncompleteOrUnknownActions() {
        #expect(AgentDecisionPayload(thought: "", action: "click").pageAction == nil)
        #expect(AgentDecisionPayload(thought: "", action: "type", elementID: 1).pageAction == nil)
        #expect(AgentDecisionPayload(thought: "", action: "navigate", url: "file:///etc/passwd").pageAction == nil)
        #expect(AgentDecisionPayload(thought: "", action: "dance").pageAction == nil)
    }

    @Test func thePromptListsElementsAndSteps() {
        let prompt = AgentInstructions.prompt(task: "Find shoes", history: [AgentStep(thought: "look", summary: "Scroll down")],
                                              page: page)
        #expect(prompt.contains("Task: Find shoes"))
        #expect(prompt.contains("1. look -> Scroll down"))
        #expect(prompt.contains("[4] button: Sign in (submits)"))
        #expect(prompt.contains("[1] link: Home -> https://shop.example/"))
    }
}

struct AgentSafetyTests {
    @Test func submittingAndRiskyLabelsNeedApproval() {
        #expect(AgentSafety.needsConfirmation(.click(elementID: 4), on: page))
        #expect(AgentSafety.needsConfirmation(.click(elementID: 3), on: page))
        #expect(AgentSafety.needsConfirmation(.type(elementID: 2, text: "x", submit: true), on: page))
    }

    @Test func ordinaryStepsDoNot() {
        #expect(!AgentSafety.needsConfirmation(.click(elementID: 1), on: page))
        #expect(!AgentSafety.needsConfirmation(.type(elementID: 2, text: "x", submit: false), on: page))
        #expect(!AgentSafety.needsConfirmation(.navigate(URL(string: "https://a.example")!), on: page))
        #expect(!AgentSafety.needsConfirmation(.click(elementID: 99), on: page))
    }

    @Test(arguments: [("Buy now", true), ("Delete account", true), ("Payment", false), ("Orders history", false),
                      ("Check out", true), ("Sender info", false)])
    func riskyWordsMatchWholeWords(label: String, expected: Bool) {
        #expect(AgentSafety.isRisky(label) == expected)
    }
}

@MainActor
struct AgentRunnerTests {
    @Test func runsStepsUntilFinished() async {
        let model = ScriptedModel([reply("type", id: 2, text: "shoes"), reply("click", id: 1),
                                   reply("finish", answer: "Found them")])
        let driver = FakeDriver(page: page)
        var steps: [AgentStep] = []
        let outcome = await AgentRunner().run(task: "t", model: model, driver: driver,
                                              confirm: { _, _ in Issue.record("No approval expected"); return false },
                                              onStep: { steps.append($0) })
        #expect(outcome == .finished(answer: "Found them"))
        #expect(driver.performed == [.type(elementID: 2, text: "shoes", submit: false), .click(elementID: 1)])
        #expect(steps.map(\.summary) == ["Type \"shoes\" into \"Search\"", "Click \"Home\"", "Finished"])
        #expect(model.prompts.last?.contains("2. because -> Click \"Home\"") == true)
    }

    @Test func approvedRiskyStepsRun() async {
        let model = ScriptedModel([reply("click", id: 3)])
        let driver = FakeDriver(page: page)
        var asked: [PageAction] = []
        let outcome = await AgentRunner().run(task: "t", model: model, driver: driver,
                                              confirm: { action, _ in asked.append(action); return true }, onStep: { _ in })
        #expect(asked == [.click(elementID: 3)])
        #expect(driver.performed == [.click(elementID: 3)])
        #expect(outcome == .finished(answer: "done"))
    }

    @Test func declinedRiskyStepsStopTheRunWithoutActing() async {
        let model = ScriptedModel([reply("click", id: 4)])
        let driver = FakeDriver(page: page)
        let outcome = await AgentRunner().run(task: "t", model: model, driver: driver,
                                              confirm: { _, _ in false }, onStep: { _ in })
        #expect(outcome == .declined)
        #expect(driver.performed.isEmpty)
    }

    @Test func badRepliesAreRetriedThenFail() async {
        let model = ScriptedModel([reply("click", id: 99), reply("dance"), reply("click")])
        let driver = FakeDriver(page: page)
        let outcome = await AgentRunner(allowedBadReplies: 2).run(task: "t", model: model, driver: driver,
                                                                  confirm: { _, _ in true }, onStep: { _ in })
        #expect(outcome == .failed("The model kept choosing steps it cannot take."))
        #expect(driver.performed.isEmpty)
    }

    @Test func oneBadReplyIsForgiven() async {
        let model = ScriptedModel([reply("click", id: 99), reply("click", id: 1)])
        let driver = FakeDriver(page: page)
        let outcome = await AgentRunner().run(task: "t", model: model, driver: driver,
                                              confirm: { _, _ in true }, onStep: { _ in })
        #expect(outcome == .finished(answer: "done"))
        #expect(driver.performed == [.click(elementID: 1)])
    }

    @Test func theStepLimitStopsTheRun() async {
        let model = ScriptedModel(Array(repeating: reply("scroll_down"), count: 10))
        let driver = FakeDriver(page: page)
        let outcome = await AgentRunner(maximumSteps: 3).run(task: "t", model: model, driver: driver,
                                                             confirm: { _, _ in true }, onStep: { _ in })
        #expect(outcome == .stepLimitReached)
        #expect(driver.performed.count == 3)
    }

    @Test func modelErrorsFailTheRun() async {
        let model = ScriptedModel([.failure(.unauthorized)])
        let outcome = await AgentRunner().run(task: "t", model: model, driver: FakeDriver(page: page),
                                              confirm: { _, _ in true }, onStep: { _ in })
        #expect(outcome == .failed("The model server refused the API key."))
    }

    @Test func driverErrorsFailTheRun() async {
        struct Gone: Error, LocalizedError { var errorDescription: String? { "gone" } }
        let driver = FakeDriver(page: page)
        driver.failure = Gone()
        let outcome = await AgentRunner().run(task: "t", model: ScriptedModel([reply("click", id: 1)]), driver: driver,
                                              confirm: { _, _ in true }, onStep: { _ in })
        #expect(outcome == .failed("Could not Click \"Home\": gone"))

        let unreadable = FakeDriver(page: page)
        unreadable.snapshotFailure = Gone()
        let second = await AgentRunner().run(task: "t", model: ScriptedModel([]), driver: unreadable,
                                             confirm: { _, _ in true }, onStep: { _ in })
        #expect(second == .failed("Could not read the page: gone"))
    }

    @Test func aCancelledTaskStops() async {
        let model = ScriptedModel(Array(repeating: reply("scroll_down"), count: 5))
        let driver = FakeDriver(page: page)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await AgentRunner().run(task: "t", model: model, driver: driver, confirm: { _, _ in true }, onStep: { _ in })
        }
        #expect(await task.value == .cancelled)
        #expect(driver.performed.isEmpty)
    }
}

struct OpenAICompatibleModelTests {
    let base = URL(string: "http://localhost:11434/v1")!

    private func chat(_ content: String) -> String {
        let escaped = String(decoding: try! JSONEncoder().encode(content), as: UTF8.self)
        return #"{"choices":[{"message":{"role":"assistant","content":"# + escaped + "}}]}"
    }

    @Test func sendsAChatRequestWithTheKey() async throws {
        let transport = StubTransport(body: chat(#"{"thought":"t","action":"scroll_down"}"#))
        let model = OpenAICompatibleModel(baseURL: base, model: "llama3.2", apiKey: "k", transport: transport)
        let payload = try await model.decide(system: "sys", prompt: "user")
        #expect(payload.action == "scroll_down")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: Any]
        #expect(body?["model"] as? String == "llama3.2")
        #expect((body?["response_format"] as? [String: String])?["type"] == "json_object")
        let messages = body?["messages"] as? [[String: String]]
        #expect(messages?.map { $0["role"] } == ["system", "user"])
    }

    @Test func noKeySendsNoAuthorization() async throws {
        let transport = StubTransport(body: chat(#"{"thought":"t","action":"finish","answer":"a"}"#))
        _ = try await OpenAICompatibleModel(baseURL: base, model: "m", apiKey: nil, transport: transport)
            .decide(system: "s", prompt: "p")
        #expect(transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func readsJSONInsideCodeFences() {
        let payload = OpenAICompatibleModel.payload(from: "Sure:\n```json\n{\"thought\":\"x\",\"action\":\"click\",\"elementID\":2}\n```")
        #expect(payload?.pageAction == .click(elementID: 2))
        #expect(OpenAICompatibleModel.payload(from: "no json here") == nil)
    }

    @Test func errorsMapToModelErrors() async {
        let model = { (transport: StubTransport) in
            OpenAICompatibleModel(baseURL: base, model: "m", apiKey: "k", transport: transport)
        }
        await #expect(throws: AgentModelError.unauthorized) {
            try await model(StubTransport(status: 401)).decide(system: "s", prompt: "p")
        }
        await #expect(throws: AgentModelError.server(status: 500, message: "down")) {
            try await model(StubTransport(status: 500, body: "down")).decide(system: "s", prompt: "p")
        }
        await #expect(throws: AgentModelError.unreadableResponse) {
            try await model(StubTransport(body: chat("not json"))).decide(system: "s", prompt: "p")
        }
        await #expect(throws: AgentModelError.notConfigured) {
            try await OpenAICompatibleModel(baseURL: base, model: "", apiKey: nil, transport: StubTransport())
                .decide(system: "s", prompt: "p")
        }
        await #expect {
            try await model(StubTransport(failure: URLError(.timedOut))).decide(system: "s", prompt: "p")
        } throws: { error in
            if case AgentModelError.network = error { return true }
            return false
        }
    }
}
