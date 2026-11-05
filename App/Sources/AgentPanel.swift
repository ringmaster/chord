import AppKit
import SwiftUI
import WebKit
import chord_logic

/// The state of one page action in a window: the task, the steps taken, a
/// pending approval, and the result. The palette starts it; the card shows it.
@MainActor
@Observable
final class AgentSession {
    /// A step that waits for the user's approval.
    struct Approval: Equatable {
        var summary: String
        /// The file text, for an overtone write.
        var code: String?
    }

    enum Phase: Equatable {
        case running
        case confirming(Approval)
        case done(AgentOutcome)
    }

    let task: String
    let modelName: String
    private(set) var phase: Phase = .running
    private(set) var steps: [AgentStep] = []
    /// True after the user asked the run to stop and before it has.
    private(set) var stopping = false
    /// The overtone folder the run wrote to, once it has written a file.
    private(set) var wroteOvertone: URL?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?

    /// Starts `task` on `webView` with `model`. With `overtones`, the model
    /// can write the overtone for the page's domain.
    init(task: String, webView: WKWebView, model: any PageAgentModel, overtones: FolderOvertoneWorkspace?) {
        self.task = task
        self.modelName = model.name
        // The Apple model has a small context, so it gets less of the page.
        let small = model is AppleAgentModel
        let driver = WebPageDriver(webView: webView, maximumText: small ? 1500 : 6000, maximumOutline: small ? 1200 : 5000)
        runTask = Task { [weak self] in
            let outcome = await AgentRunner().run(
                task: task, model: model, driver: driver, overtones: overtones,
                confirm: { [weak self] action, page in
                    await self?.askApproval(action, on: page) ?? false
                },
                onStep: { [weak self] step in
                    self?.steps.append(step)
                    if let overtones, overtones.hasWritten {
                        self?.wroteOvertone = overtones.folder
                    }
                })
            self?.phase = .done(outcome)
            self?.runTask = nil
        }
    }

    var isDone: Bool {
        if case .done = phase { return true }
        return false
    }

    private func askApproval(_ action: PageAction, on page: PageSnapshot) async -> Bool {
        var code: String?
        if case .writeOvertone(_, let content) = action, !content.isEmpty {
            code = content
        }
        phase = .confirming(Approval(summary: AgentRunner.summarize(action, on: page), code: code))
        let allowed = await withCheckedContinuation { approval = $0 }
        if !isDone { phase = .running }
        return allowed
    }

    func answer(_ allowed: Bool) {
        approval?.resume(returning: allowed)
        approval = nil
    }

    /// Stops the run. A model call in progress is cancelled; the outcome
    /// arrives when it returns.
    func stop() {
        guard !isDone else { return }
        stopping = true
        answer(false)
        runTask?.cancel()
    }

    /// What Escape does: stops a run that is still going, and returns true
    /// when the card should close instead.
    func escape() -> Bool {
        if isDone || stopping { return true }
        stop()
        return false
    }
}

/// The card at the bottom of the page that shows a page action as it runs.
/// Escape stops the run, then closes the card.
struct AgentCard: View {
    let session: AgentSession
    let onClose: () -> Void
    let onChooseModel: () -> Void
    let onRevealOvertone: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !session.steps.isEmpty || session.phase == .running {
                stepList
            }
            footer
        }
        .padding(16)
        .frame(width: 560)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Icon("sparkles", size: 16)
                .foregroundStyle(.tint)
            Text(session.task)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            Spacer()
            Button(action: onChooseModel) {
                Text(session.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .contentShape(Capsule())
            }
            .buttonStyle(ChromeButtonStyle(shape: .capsule))
            .help("Choose the model for page actions")
            Button(action: onClose) {
                Icon("x", size: 12).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(ChromeButtonStyle(shape: .circle))
            .help("Close (Escape)")
        }
    }

    private var stepList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.summary).font(.system(size: 12.5, weight: .medium))
                                Text(step.thought).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .id(index)
                    }
                    if session.phase == .running {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(session.stopping ? "Stopping…" : (session.steps.isEmpty ? "Reading the page…" : "Working…"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: session.steps.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch session.phase {
        case .confirming(let approval):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Icon("hand-stop", size: 17).foregroundStyle(.orange)
                    Text("Allow: \(approval.summary)?").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Button("Stop") { session.stop() }.buttonStyle(QuietButtonStyle())
                    // The window controller reads Return for Allow, because
                    // the page keeps keyboard focus while the card shows.
                    Button("Allow ↩") { session.answer(true) }.buttonStyle(QuietButtonStyle(prominent: true))
                }
                if let code = approval.code {
                    ScrollView(.vertical) {
                        Text(code)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.08)))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
        case .running:
            HStack {
                Spacer()
                KeyHint(text: session.stopping ? "esc to close" : "esc to stop")
                Button("Stop") { session.stop() }.buttonStyle(QuietButtonStyle()).disabled(session.stopping)
            }
        case .done(let outcome):
            HStack(alignment: .top, spacing: 10) {
                Icon(icon(for: outcome), size: 17).foregroundStyle(color(for: outcome))
                Text(message(for: outcome)).font(.system(size: 13)).textSelection(.enabled)
                Spacer()
                if let folder = session.wroteOvertone {
                    Button("Show Overtone") { onRevealOvertone(folder) }.buttonStyle(QuietButtonStyle())
                }
                KeyHint(text: "esc to close")
            }
        }
    }

    private func message(for outcome: AgentOutcome) -> String {
        switch outcome {
        case .finished(let answer): answer
        case .declined: "Stopped before the step you did not allow."
        case .cancelled: "Stopped."
        case .stepLimitReached: "Stopped after the step limit. Try a smaller task."
        case .failed(let reason): reason
        }
    }

    private func icon(for outcome: AgentOutcome) -> String {
        if case .finished = outcome { return "circle-check-filled" }
        if case .failed = outcome { return "alert-triangle-filled" }
        return "player-stop"
    }

    private func color(for outcome: AgentOutcome) -> Color {
        if case .finished = outcome { return .green }
        if case .failed = outcome { return .orange }
        return .secondary
    }
}

/// A small label that names a key and what it does, such as "esc to close".
private struct KeyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().strokeBorder(.primary.opacity(0.12)))
    }
}

/// The sheet that chooses the model for page actions.
struct AgentModelSheet: View {
    let library: Library
    let onDone: () -> Void
    @State private var provider: AgentSettings.Provider = .apple
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Model for Page Actions").font(.system(size: 17, weight: .bold, design: .rounded))
            ProviderCard(title: "Apple Intelligence", detail: AppleAgentModel.unavailableReason ?? "Runs on this Mac. Nothing leaves it.",
                         symbol: "brand-apple", selected: provider == .apple) { provider = .apple }
            ProviderCard(title: "OpenAI-compatible server",
                         detail: "Ollama, LM Studio, vLLM, OpenRouter, or any server with /chat/completions.",
                         symbol: "server", selected: provider == .openAICompatible) { provider = .openAICompatible }
            if provider == .openAICompatible {
                VStack(spacing: 8) {
                    SheetField(label: "Server", text: $baseURL, prompt: "http://localhost:11434/v1")
                    SheetField(label: "Model", text: $model, prompt: "llama3.2")
                    SheetField(label: "API key (optional)", text: $apiKey, prompt: "Leave empty for a local server", secure: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") {
                    AgentSettings.save(provider: provider, baseURL: baseURL, model: model,
                                       apiKey: provider == .openAICompatible ? apiKey : nil, library: library)
                    onDone()
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(provider == .openAICompatible && (URL(string: baseURL)?.host() == nil || model.isEmpty))
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            provider = AgentSettings.provider(library)
            baseURL = AgentSettings.baseURL(library)
            model = AgentSettings.modelName(library)
        }
    }
}

private struct ProviderCard: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Icon(symbol, size: 22).frame(width: 28)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Icon(selected ? "circle-check-filled" : "circle", size: 18)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.12) : .primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(ChromeButtonStyle(shape: .roundedRectangle(cornerRadius: 12)))
    }
}

private struct SheetField: View {
    let label: String
    @Binding var text: String
    let prompt: String
    var secure = false

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Group {
                if secure { SecureField("", text: $text, prompt: Text(prompt)) } else { TextField("", text: $text, prompt: Text(prompt)) }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.06)))
        }
    }
}
