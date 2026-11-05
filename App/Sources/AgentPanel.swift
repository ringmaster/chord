import AppKit
import SwiftUI
import WebKit
import chord_logic

/// The state of a page action in one window: the task text, the steps taken,
/// a pending approval, and the result.
@MainActor
@Observable
final class AgentSession {
    enum Phase: Equatable {
        case composing
        case running
        /// An action is waiting for the user's approval.
        case confirming(String)
        case done(AgentOutcome)
    }

    var task = ""
    private(set) var phase: Phase = .composing
    private(set) var steps: [AgentStep] = []
    private(set) var modelName = ""

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var approval: CheckedContinuation<Bool, Never>?
    @ObservationIgnored let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    /// Starts the task on `webView` with `model`.
    func start(webView: WKWebView, model: any PageAgentModel) {
        let text = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runTask == nil else { return }
        steps = []
        modelName = model.name
        phase = .running
        // The Apple model has a small context, so it gets less page text.
        let driver = WebPageDriver(webView: webView, maximumText: model is AppleAgentModel ? 1500 : 6000)
        runTask = Task { [weak self] in
            let outcome = await AgentRunner().run(
                task: text, model: model, driver: driver,
                confirm: { [weak self] action, page in
                    await self?.askApproval(AgentRunner.summarize(action, on: page)) ?? false
                },
                onStep: { [weak self] step in self?.steps.append(step) })
            self?.phase = .done(outcome)
            self?.runTask = nil
        }
    }

    private func askApproval(_ summary: String) async -> Bool {
        phase = .confirming(summary)
        let allowed = await withCheckedContinuation { approval = $0 }
        phase = .running
        return allowed
    }

    func answer(_ allowed: Bool) {
        approval?.resume(returning: allowed)
        approval = nil
    }

    func stop() {
        answer(false)
        runTask?.cancel()
    }

    func reset() {
        stop()
        runTask = nil
        steps = []
        phase = .composing
    }
}

/// The card at the bottom of the page for page actions.
struct AgentCard: View {
    @Bindable var session: AgentSession
    let modelLabel: String
    let onRun: () -> Void
    let onChooseModel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            switch session.phase {
            case .composing:
                composer
            case .running, .confirming, .done:
                stepList
                footer
            }
        }
        .padding(16)
        .frame(width: 560)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Icon("sparkles", size: 16)
                .foregroundStyle(.tint)
            Text(session.phase == .composing ? "Ask Chord to do something on this page" : session.task)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button(action: onChooseModel) {
                Text(session.phase == .composing ? modelLabel : session.modelName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .contentShape(Capsule())
            }
            .buttonStyle(ChromeButtonStyle(shape: .capsule))
            .help("Choose the model for page actions")
            Button {
                session.stop()
                session.onClose()
            } label: {
                Icon("x", size: 12).foregroundStyle(.secondary)
                    .frame(width: 20, height: 20).background(Circle().fill(.primary.opacity(0.08)))
            }
            .buttonStyle(ChromeButtonStyle(shape: .circle))
            .keyboardShortcut(.cancelAction)
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("", text: $session.task, prompt: Text("Find the cheapest flight on this page, then open it"), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(onRun)
            Button("Run", action: onRun)
                .buttonStyle(QuietButtonStyle(prominent: true))
                .disabled(session.task.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.06)))
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
                            Text("Working…").font(.system(size: 12)).foregroundStyle(.secondary)
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
        case .confirming(let summary):
            HStack(spacing: 10) {
                Icon("hand-stop", size: 17).foregroundStyle(.orange)
                Text("Allow: \(summary)?").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Spacer()
                Button("Stop") { session.answer(false) }.buttonStyle(QuietButtonStyle())
                Button("Allow") { session.answer(true) }.buttonStyle(QuietButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
        case .running:
            HStack {
                Spacer()
                Button("Stop") { session.stop() }.buttonStyle(QuietButtonStyle())
            }
        case .done(let outcome):
            HStack(alignment: .top, spacing: 10) {
                Icon(icon(for: outcome), size: 17).foregroundStyle(color(for: outcome))
                Text(message(for: outcome)).font(.system(size: 13)).textSelection(.enabled)
                Spacer()
                Button("New Task") { session.reset() }.buttonStyle(QuietButtonStyle())
            }
        case .composing:
            EmptyView()
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
