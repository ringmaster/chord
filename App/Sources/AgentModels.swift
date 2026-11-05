import Foundation
import FoundationModels
import chord_logic

/// The step reply, in the form the Apple model generates. It matches
/// `AgentDecisionPayload`, which every provider returns.
@Generable
struct AppleAgentReply {
    @Guide(description: "Why this step moves the task forward")
    var thought: String
    @Guide(description: "One of: click, type, navigate, scroll_down, scroll_up, write_overtone, finish")
    var action: String
    @Guide(description: "The number of the element to click or type into, if any")
    var elementID: Int?
    @Guide(description: "The text to type, if the action is type")
    var text: String?
    @Guide(description: "The full http or https address, if the action is navigate")
    var url: String?
    @Guide(description: "True to press Return after typing")
    var submit: Bool?
    @Guide(description: "The overtone file name, such as style.css, if the action is write_overtone")
    var file: String?
    @Guide(description: "The whole new text of that file, if the action is write_overtone")
    var content: String?
    @Guide(description: "What to tell the user, if the action is finish")
    var answer: String?
}

/// The native Apple model, through the Foundation Models framework. It runs
/// on this Mac and needs Apple Intelligence turned on.
struct AppleAgentModel: PageAgentModel {
    let name = "Apple Intelligence"

    /// Why the model cannot run, or nil when it can.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in System Settings."
        case .unavailable(.modelNotReady):
            return "The Apple model is still downloading."
        case .unavailable:
            return "The Apple model is not available."
        }
    }

    func decide(system: String, prompt: String) async throws -> AgentDecisionPayload {
        if let reason = Self.unavailableReason {
            throw AgentModelError.unavailable(reason)
        }
        // Each step starts a new session, so the model's small context holds
        // only the current page and the step list in the prompt.
        let session = LanguageModelSession(instructions: system)
        do {
            let reply = try await session.respond(to: prompt, generating: AppleAgentReply.self).content
            return AgentDecisionPayload(thought: reply.thought, action: reply.action, elementID: reply.elementID,
                                        text: reply.text, url: reply.url, submit: reply.submit,
                                        file: reply.file, content: reply.content, answer: reply.answer)
        } catch {
            throw AgentModelError.unavailable(error.localizedDescription)
        }
    }
}

/// Which model runs page actions, stored in settings. The API key for an
/// OpenAI-compatible server is in the Keychain.
@MainActor
enum AgentSettings {
    static let keyAccount = "agent-api-key"

    enum Provider: String {
        case apple
        case openAICompatible = "openai"
    }

    static func provider(_ library: Library) -> Provider {
        (try? library.database.setting(.agentProvider)).flatMap(Provider.init(rawValue:)) ?? .apple
    }

    static func baseURL(_ library: Library) -> String {
        (try? library.database.setting(.agentBaseURL)) ?? "http://localhost:11434/v1"
    }

    static func modelName(_ library: Library) -> String {
        (try? library.database.setting(.agentModel)) ?? ""
    }

    static func save(provider: Provider, baseURL: String, model: String, apiKey: String?, library: Library) {
        try? library.database.setSetting(.agentProvider, to: provider.rawValue)
        try? library.database.setSetting(.agentBaseURL, to: baseURL)
        try? library.database.setSetting(.agentModel, to: model)
        if let apiKey {
            Keychain.write(keyAccount, apiKey.isEmpty ? nil : apiKey)
        }
    }

    /// The model to use now. The Apple model is returned even when it is not
    /// available; its first step reports why.
    static func model(_ library: Library) -> any PageAgentModel {
        switch provider(library) {
        case .apple:
            return AppleAgentModel()
        case .openAICompatible:
            guard let url = URL(string: baseURL(library)) else { return AppleAgentModel() }
            return OpenAICompatibleModel(baseURL: url, model: modelName(library), apiKey: Keychain.read(keyAccount))
        }
    }
}
