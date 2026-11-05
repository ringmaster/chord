import Foundation

// MARK: The page as the model sees it

/// One element the model can act on, numbered by the page driver.
public struct PageElement: Codable, Equatable, Sendable {
    public var id: Int
    /// "link", "button", "textbox", "checkbox", "select", and so on.
    public var role: String
    /// The visible text, label, or placeholder.
    public var label: String
    public var href: String?
    /// True for a submit button, or a field whose Return key submits a form.
    public var submits: Bool

    public init(id: Int, role: String, label: String, href: String? = nil, submits: Bool = false) {
        self.id = id
        self.role = role
        self.label = label
        self.href = href
        self.submits = submits
    }
}

/// What the model is shown of the current page.
public struct PageSnapshot: Codable, Equatable, Sendable {
    public var url: String
    public var title: String
    /// The page's visible text, shortened.
    public var text: String
    public var elements: [PageElement]
    /// An indented outline of the page's elements with their ids and classes,
    /// shortened, so the model can write CSS selectors for an overtone.
    public var outline: String?

    public init(url: String, title: String, text: String, elements: [PageElement], outline: String? = nil) {
        self.url = url
        self.title = title
        self.text = text
        self.elements = elements
        self.outline = outline
    }

    /// The snapshot as prompt text: the address, title, numbered elements,
    /// the text, then the outline when there is one.
    public var promptText: String {
        let list = elements.map { element in
            var line = "[\(element.id)] \(element.role): \(element.label)"
            if let href = element.href { line += " -> \(href)" }
            if element.submits { line += " (submits)" }
            return line
        }.joined(separator: "\n")
        var result = "URL: \(url)\nTitle: \(title)\n\nElements:\n\(list)\n\nText:\n\(text)"
        if let outline, !outline.isEmpty {
            result += "\n\nOutline:\n\(outline)"
        }
        return result
    }
}

// MARK: Actions

/// One step the model can take.
public enum PageAction: Equatable, Sendable {
    case click(elementID: Int)
    /// Types into a field. With `submit`, presses Return afterward.
    case type(elementID: Int, text: String, submit: Bool)
    case navigate(URL)
    case scroll(down: Bool)
    /// Writes one file of the overtone for the current page's domain. Empty
    /// `content` deletes the file.
    case writeOvertone(file: String, content: String)
    /// The task is done. `answer` is what to tell the user.
    case finish(answer: String)
}

/// The model's answer for one step, in the flat shape every provider returns:
/// `{"thought": "...", "action": "click", "elementID": 3, "text": null, "url": null, "file": null, "content": null, "answer": null}`.
public struct AgentDecisionPayload: Codable, Equatable, Sendable {
    public var thought: String
    public var action: String
    public var elementID: Int?
    public var text: String?
    public var url: String?
    public var submit: Bool?
    /// The overtone file name, for write_overtone.
    public var file: String?
    /// The whole new text of that file, for write_overtone.
    public var content: String?
    public var answer: String?

    public init(thought: String, action: String, elementID: Int? = nil, text: String? = nil,
                url: String? = nil, submit: Bool? = nil, file: String? = nil, content: String? = nil,
                answer: String? = nil) {
        self.thought = thought
        self.action = action
        self.elementID = elementID
        self.text = text
        self.url = url
        self.submit = submit
        self.file = file
        self.content = content
        self.answer = answer
    }

    /// The action, or nil when the payload names an unknown action or
    /// leaves out a field the action needs.
    public var pageAction: PageAction? {
        switch action.lowercased() {
        case "click":
            return elementID.map { .click(elementID: $0) }
        case "type":
            guard let elementID, let text else { return nil }
            return .type(elementID: elementID, text: text, submit: submit ?? false)
        case "navigate":
            guard let url = url.flatMap(URL.init(string:)), HistoryRanking.isRecordable(url) else { return nil }
            return .navigate(url)
        case "scroll_down":
            return .scroll(down: true)
        case "scroll_up":
            return .scroll(down: false)
        case "write_overtone":
            guard let file, OvertoneFiles.isValidName(file) else { return nil }
            return .writeOvertone(file: file, content: content ?? "")
        case "finish":
            return .finish(answer: answer ?? thought)
        default:
            return nil
        }
    }
}

/// The instructions every provider gives the model.
public enum AgentInstructions {
    public static let system = """
        You operate a web browser for the user, one step at a time. Each turn you see the current page \
        with its numbered elements and an outline of its structure, the overtone files for the page's \
        domain, the task, and the steps taken so far.
        Answer with one JSON object and nothing else:
        {"thought": "why this step", \
        "action": "click|type|navigate|scroll_down|scroll_up|write_overtone|finish", \
        "elementID": number or null, "text": string or null, "url": string or null, \
        "submit": true or false or null, "file": string or null, "content": string or null, \
        "answer": string or null}
        - click needs elementID. type needs elementID and text; set submit to true to press Return.
        - navigate needs a full http or https url.
        - write_overtone needs file and content. It replaces that whole file; empty content deletes it.
        - finish needs answer: what to tell the user, including any information they asked for.
        Use only element numbers shown on the current page. Do not invent information.

        Overtones are the main tool for changing a site. An overtone is a folder of files that Chord \
        adds to every page of the domain each time a page loads:
        - .css files are added as a style sheet when the page starts loading.
        - .html files are added at the end of the body when the page has loaded.
        - .js files run after the HTML is in place. They share the page's DOM but not its JavaScript \
        variables. Use a MutationObserver for content that the page adds later.
        File names use letters, digits, "-", and "_", and end in .css, .js, or .html, such as style.css.
        When the task asks to change how a site looks or behaves, write an overtone. Use selectors from \
        the outline. Write each file complete, because a write replaces it. After a write, the page \
        reloads with the overtone. Check the result, then finish and say what you changed.
        """

    /// The prompt for one step. It starts with the current page, then the
    /// domain's overtone, the task, and the steps so far.
    public static func prompt(task: String, history: [AgentStep], page: PageSnapshot,
                              overtone: OvertoneContext? = nil) -> String {
        let steps = history.isEmpty ? "None yet." : history.enumerated().map { index, step in
            "\(index + 1). \(step.thought) -> \(step.summary)"
        }.joined(separator: "\n")
        var parts = ["Current page:\n\(page.promptText)"]
        if let overtone {
            parts.append("Overtone for this domain (\(overtone.folderName)):\n\(overtone.promptText)")
        }
        parts.append("Task: \(task)")
        parts.append("Steps so far:\n\(steps)")
        return parts.joined(separator: "\n\n")
    }
}

// MARK: Providers and drivers

public enum AgentModelError: Error, Equatable {
    case notConfigured
    /// The model is not available on this Mac, such as Apple Intelligence turned off.
    case unavailable(String)
    case unauthorized
    case server(status: Int, message: String)
    case network(String)
    case unreadableResponse
}

/// A language model that chooses the next step. Implementations: an
/// OpenAI-compatible endpoint, and the native Apple model.
///
/// Contract:
/// - Returns one decision per call. It may name an action the runner rejects.
/// - Throws only `AgentModelError`.
/// - Does not retry; the runner decides what happens after a failure.
public protocol PageAgentModel: Sendable {
    var name: String { get }
    func decide(system: String, prompt: String) async throws -> AgentDecisionPayload
}

/// Reads the page and acts on it. The app's driver runs scripts in an
/// isolated content world of the tab's web view.
///
/// Contract: `snapshot` numbers the elements, and `perform` acts on those
/// numbers from the latest snapshot. Both throw when the page cannot be read
/// or the element is gone.
@MainActor
public protocol PageDriver: AnyObject {
    func snapshot() async throws -> PageSnapshot
    func perform(_ action: PageAction) async throws
}

/// The overtone for the current page's domain, as the model sees it.
public struct OvertoneContext: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var name: String
        public var content: String

        public init(name: String, content: String) {
            self.name = name
            self.content = content
        }
    }

    /// The overtone's folder name, such as "github.com".
    public var folderName: String
    /// The files, in name order.
    public var files: [File]

    public init(folderName: String, files: [File]) {
        self.folderName = folderName
        self.files = files
    }

    /// Each file under its name, or a note that there are none yet. Long
    /// files are shortened.
    public var promptText: String {
        guard !files.isEmpty else { return "No files yet." }
        return files.map { file in
            let limit = OvertoneFiles.maximumPromptCharacters
            let text = file.content.count > limit ? String(file.content.prefix(limit)) + "\n… (shortened)" : file.content
            return "--- \(file.name)\n\(text)"
        }.joined(separator: "\n")
    }
}

/// Reads and writes the overtone for the page the agent is on. The app's
/// workspace writes into the overtones folder and waits for the page to
/// reload with the change.
///
/// Contract: `context` returns the current files. `write` replaces one file,
/// or deletes it when `content` is empty, and throws when it cannot.
@MainActor
public protocol OvertoneWorkspace: AnyObject {
    func context() -> OvertoneContext
    func write(file: String, content: String) async throws
}

// MARK: Safety

public enum AgentSafety {
    /// Words in a label that mark an action the user must approve.
    public static let riskyWords = ["buy", "purchase", "pay", "order", "checkout", "check out", "subscribe",
                                    "delete", "remove", "send", "transfer", "confirm", "place"]

    /// Whether the user must approve `action` first: submitting a form, or
    /// clicking something whose label sounds like spending, sending, or deleting.
    public static func needsConfirmation(_ action: PageAction, on page: PageSnapshot) -> Bool {
        switch action {
        case .click(let id):
            guard let element = page.elements.first(where: { $0.id == id }) else { return false }
            return element.submits || isRisky(element.label)
        case .type(_, _, let submit):
            return submit
        case .writeOvertone:
            // An overtone runs on every visit to the domain, so text on a
            // page must not be able to plant one without the user seeing it.
            return true
        case .navigate, .scroll, .finish:
            return false
        }
    }

    static func isRisky(_ label: String) -> Bool {
        let words = label.lowercased()
        return riskyWords.contains { word in
            words.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil
        }
    }
}

// MARK: The loop

/// One step the agent took, for the progress list and the next prompt.
public struct AgentStep: Equatable, Sendable {
    public var thought: String
    public var summary: String

    public init(thought: String, summary: String) {
        self.thought = thought
        self.summary = summary
    }
}

public enum AgentOutcome: Equatable, Sendable {
    case finished(answer: String)
    /// The user declined an action that needed approval.
    case declined
    case cancelled
    case stepLimitReached
    case failed(String)
}

/// Runs the read, decide, act loop until the model finishes, the user stops
/// it, an approval is declined, or the step limit is reached.
@MainActor
public struct AgentRunner {
    public var maximumSteps: Int
    /// A reply the model gets wrong is shown to it once more before the run fails.
    public var allowedBadReplies: Int

    public init(maximumSteps: Int = 12, allowedBadReplies: Int = 2) {
        self.maximumSteps = maximumSteps
        self.allowedBadReplies = allowedBadReplies
    }

    public func run(task: String, model: any PageAgentModel, driver: any PageDriver,
                    overtones: (any OvertoneWorkspace)? = nil,
                    confirm: (PageAction, PageSnapshot) async -> Bool,
                    onStep: (AgentStep) -> Void) async -> AgentOutcome {
        var history: [AgentStep] = []
        var badReplies = 0
        for _ in 0..<maximumSteps {
            if Task.isCancelled { return .cancelled }
            let page: PageSnapshot
            do {
                page = try await driver.snapshot()
            } catch {
                return .failed("Could not read the page: \(error.localizedDescription)")
            }

            let payload: AgentDecisionPayload
            do {
                payload = try await model.decide(system: AgentInstructions.system,
                                                 prompt: AgentInstructions.prompt(task: task, history: history, page: page,
                                                                                  overtone: overtones?.context()))
            } catch {
                return .failed(Self.describe(error))
            }
            if Task.isCancelled { return .cancelled }

            guard let action = payload.pageAction,
                  Self.isValid(action, on: page, canWriteOvertones: overtones != nil) else {
                badReplies += 1
                let step = AgentStep(thought: payload.thought, summary: "Invalid step (\(payload.action)); try again")
                history.append(step)
                onStep(step)
                if badReplies > allowedBadReplies { return .failed("The model kept choosing steps it cannot take.") }
                continue
            }

            if case .finish(let answer) = action {
                onStep(AgentStep(thought: payload.thought, summary: "Finished"))
                return .finished(answer: answer)
            }

            if AgentSafety.needsConfirmation(action, on: page) {
                guard await confirm(action, page) else { return .declined }
            }

            do {
                if case .writeOvertone(let file, let content) = action, let overtones {
                    try await overtones.write(file: file, content: content)
                } else {
                    try await driver.perform(action)
                }
            } catch {
                return .failed("Could not \(Self.summarize(action, on: page)): \(error.localizedDescription)")
            }
            let step = AgentStep(thought: payload.thought, summary: Self.summarize(action, on: page))
            history.append(step)
            onStep(step)
        }
        return .stepLimitReached
    }

    /// An action is valid when the elements it names are on the page.
    /// An overtone write is valid only when the run has a workspace and the
    /// file is not too large.
    static func isValid(_ action: PageAction, on page: PageSnapshot, canWriteOvertones: Bool = false) -> Bool {
        switch action {
        case .click(let id), .type(let id, _, _):
            return page.elements.contains { $0.id == id }
        case .writeOvertone(_, let content):
            return canWriteOvertones && content.utf8.count <= OvertoneFiles.maximumFileBytes
        case .navigate, .scroll, .finish:
            return true
        }
    }

    /// A short description of an action, such as `Click "Sign in"`.
    public static func summarize(_ action: PageAction, on page: PageSnapshot) -> String {
        func label(_ id: Int) -> String {
            page.elements.first { $0.id == id }.map { "\"\($0.label)\"" } ?? "element \(id)"
        }
        switch action {
        case .click(let id): return "Click \(label(id))"
        case .type(let id, let text, let submit): return "Type \"\(text)\" into \(label(id))\(submit ? " and submit" : "")"
        case .navigate(let url): return "Go to \(url.absoluteString)"
        case .scroll(let down): return down ? "Scroll down" : "Scroll up"
        case .writeOvertone(let file, let content):
            return content.isEmpty ? "Delete overtone file \(file)" : "Write overtone file \(file)"
        case .finish: return "Finish"
        }
    }

    static func describe(_ error: Error) -> String {
        switch error as? AgentModelError {
        case .notConfigured: return "No model is set up for page actions."
        case .unavailable(let reason): return "The model is not available: \(reason)"
        case .unauthorized: return "The model server refused the API key."
        case .server(let status, let message): return "The model server answered \(status): \(message)"
        case .network(let message): return "Could not reach the model: \(message)"
        case .unreadableResponse: return "The model's answer was not in the expected shape."
        case nil: return error.localizedDescription
        }
    }
}

// MARK: OpenAI-compatible endpoint

/// A model behind an OpenAI-compatible chat completions endpoint, such as
/// Ollama (`http://localhost:11434/v1`), LM Studio, vLLM, or OpenRouter.
public struct OpenAICompatibleModel: PageAgentModel {
    public let baseURL: URL
    public let model: String
    let apiKey: String?
    let transport: any HTTPTransport

    public var name: String { model }

    public init(baseURL: URL, model: String, apiKey: String?, transport: any HTTPTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
    }

    func makeRequest(system: String, prompt: String) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body = ChatRequest(model: model, messages: [.init(role: "system", content: system),
                                                         .init(role: "user", content: prompt)],
                               temperature: 0, responseFormat: .init(type: "json_object"))
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    public func decide(system: String, prompt: String) async throws -> AgentDecisionPayload {
        guard !model.isEmpty else { throw AgentModelError.notConfigured }
        let request: URLRequest
        do {
            request = try makeRequest(system: system, prompt: prompt)
        } catch {
            throw AgentModelError.unreadableResponse
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw AgentModelError.network(error.localizedDescription)
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw AgentModelError.unauthorized
        default: throw AgentModelError.server(status: response.statusCode, message: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let reply = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = reply.choices.first?.message.content,
              let payload = Self.payload(from: content) else {
            throw AgentModelError.unreadableResponse
        }
        return payload
    }

    /// Reads the JSON object out of a reply, ignoring text or code fences around it.
    static func payload(from content: String) -> AgentDecisionPayload? {
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(AgentDecisionPayload.self, from: Data(content[start...end].utf8))
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable { var role: String; var content: String }
        struct Format: Encodable { var type: String }
        var model: String
        var messages: [Message]
        var temperature: Double
        var responseFormat: Format

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case responseFormat = "response_format"
        }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { var message: Message }
        struct Message: Decodable { var content: String? }
        var choices: [Choice]
    }
}
