import Foundation
import Observation

/// Führt Gespräche mit DeepSeek, inkl. Werkzeug-Schleife und Bestätigungen.
@MainActor
@Observable
final class Assistant {
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let continuation: CheckedContinuation<Bool, Never>
    }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?

    var threads: [String: ChatThread] = [:]
    var scopeModuleID: UUID?
    var isRunning = false
    var live: StreamResult?
    var activity: String?
    var confirmation: Confirmation?
    var errorText: String?
    var draft = ""

    var key: String { scopeModuleID?.uuidString ?? "general" }
    var messages: [AIMessage] { threads[key]?.messages ?? [] }

    func load(from store: DataStore) {
        threads = store.loadChats()
    }

    private func persist() {
        app?.store.saveChats(threads)
    }

    // MARK: Steuerung

    func send(_ text: String) {
        let t = text.trimmed
        guard !t.isEmpty, !isRunning else { return }
        errorText = nil
        let runKey = key
        append(AIMessage(role: .user, content: t), to: runKey)
        draft = ""
        task = Task { await runLoop(key: runKey) }
    }

    func stop() {
        task?.cancel()
        if let c = confirmation {
            confirmation = nil
            c.continuation.resume(returning: false)
        }
    }

    func resolve(_ approved: Bool) {
        guard let c = confirmation else { return }
        confirmation = nil
        c.continuation.resume(returning: approved)
    }

    func clear() {
        stop()
        threads[key] = ChatThread()
        errorText = nil
        persist()
    }

    /// Startet eine Unterhaltung mit vorbereiteter Nachricht (z. B. aus einem Modul heraus).
    func ask(_ text: String, scope: UUID?) {
        scopeModuleID = scope
        app?.showAssistant = true
        send(text)
    }

    private func append(_ m: AIMessage, to key: String) {
        var t = threads[key] ?? ChatThread()
        t.messages.append(m)
        t.updatedAt = Date()
        threads[key] = t
    }

    // MARK: Werkzeug-Schleife

    private func runLoop(key runKey: String) async {
        guard let app else { return }
        isRunning = true
        defer {
            isRunning = false
            live = nil
            activity = nil
            persist()
        }
        guard var client = DeepSeekClient.fromSettings(app.store.prefs) else {
            errorText = "Hinterlege zuerst deinen DeepSeek-API-Key in den Einstellungen (⌘,) → KI."
            return
        }
        let executor = ToolExecutor(app: app)
        let scope = UUID(uuidString: runKey)

        for _ in 0..<12 {
            if Task.isCancelled { return }
            let payload = buildPayload(key: runKey, scope: scope, model: client.model)
            activity = nil
            do {
                live = StreamResult()
                let result = try await client.stream(messages: payload, tools: ToolDefinitions.all,
                                                     temperature: app.store.prefs.aiTemperature) { [weak self] partial in
                    self?.live = partial
                    if let n = partial.pendingToolNames.last, !n.isEmpty { self?.activity = ToolDefinitions.activityLabel(n) }
                }
                live = nil
                append(AIMessage(role: .assistant, content: result.content, reasoning: result.reasoning.nilIfEmpty,
                                 toolCalls: result.toolCalls.isEmpty ? nil : result.toolCalls), to: runKey)
                if result.toolCalls.isEmpty { return }

                for call in result.toolCalls {
                    if Task.isCancelled {
                        append(AIMessage(role: .tool, content: "{\"fehler\":\"abgebrochen\"}", toolCallID: call.id, toolName: call.name, summary: "Abgebrochen", isError: true), to: runKey)
                        continue
                    }
                    activity = ToolDefinitions.activityLabel(call.name)
                    let args = ToolArgs(call.arguments)
                    var outcome: ToolOutcome
                    if let c = executor.confirmation(for: call.name, args: args) {
                        let approved = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                            confirmation = Confirmation(title: c.title, detail: c.detail, continuation: cont)
                        }
                        outcome = approved ? await executor.run(call.name, args)
                            : ToolOutcome(result: "{\"status\":\"abgelehnt\",\"hinweis\":\"Der Nutzer hat diese Aktion abgelehnt.\"}", summary: "Abgelehnt: \(c.title)", isError: true)
                    } else {
                        outcome = await executor.run(call.name, args)
                    }
                    append(AIMessage(role: .tool, content: outcome.result, toolCallID: call.id, toolName: call.name,
                                     summary: outcome.summary, isError: outcome.isError, attachment: outcome.attachment), to: runKey)
                }
            } catch is CancellationError {
                return
            } catch let e as URLError where e.code == .cancelled {
                return
            } catch let e as AIError where client.model.contains("reasoner") && !client.model.contains("chat") {
                // Ältere Denkmodelle unterstützen keine Werkzeuge → für diese Anfrage auf deepseek-chat ausweichen.
                _ = e
                client = DeepSeekClient(apiKey: client.apiKey, baseURL: client.baseURL, model: "deepseek-chat")
                live = nil
                continue
            } catch {
                live = nil
                errorText = (error as? AIError)?.message ?? Self.describe(error)
                return
            }
        }
        errorText = "Die KI hat zu viele Schritte gebraucht und wurde gestoppt."
    }

    private static func describe(_ error: Error) -> String {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "Keine Internetverbindung."
            case .timedOut: return "Zeitüberschreitung – DeepSeek antwortet gerade nicht."
            default: return u.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Baut den Verlauf für die API (gekürzt, konsistent bei Tool-Calls).
    private func buildPayload(key: String, scope: UUID?, model: String) -> [[String: Any]] {
        guard let app else { return [] }
        var msgs: [[String: Any]] = [["role": "system", "content": Prompts.system(app: app, scope: scope)]]
        var history = Array((threads[key]?.messages ?? []).suffix(48))
        while let f = history.first, f.role != .user { history.removeFirst() }
        let lastUser = history.lastIndex { $0.role == .user } ?? 0
        let isReasoner = model.contains("reasoner")

        var i = 0
        while i < history.count {
            let m = history[i]
            switch m.role {
            case .user:
                msgs.append(["role": "user", "content": m.content])
            case .assistant:
                let calls = m.toolCalls ?? []
                if calls.isEmpty && m.content.trimmed.isEmpty { i += 1; continue }
                var d: [String: Any] = ["role": "assistant", "content": m.content]
                if !calls.isEmpty {
                    d["tool_calls"] = calls.map { c -> [String: Any] in
                        ["id": c.id, "type": "function", "function": ["name": c.name, "arguments": c.arguments]]
                    }
                }
                if isReasoner, i > lastUser, let r = m.reasoning { d["reasoning_content"] = r }
                msgs.append(d)
                // Zu jedem Tool-Call muss eine Antwort folgen – fehlende ergänzen.
                var answered = Set<String>()
                var j = i + 1
                while j < history.count, history[j].role == .tool {
                    let t = history[j]
                    if let cid = t.toolCallID, calls.contains(where: { $0.id == cid }) {
                        var content = t.content
                        if j < lastUser, content.count > 2500 { content = String(content.prefix(2500)) + " …(gekürzt)" }
                        msgs.append(["role": "tool", "tool_call_id": cid, "content": content])
                        answered.insert(cid)
                    }
                    j += 1
                }
                for c in calls where !answered.contains(c.id) {
                    msgs.append(["role": "tool", "tool_call_id": c.id, "content": "{\"fehler\":\"abgebrochen\"}"])
                }
                i = j
                continue
            case .tool:
                break // verwaiste Tool-Antworten überspringen
            }
            i += 1
        }
        return msgs
    }
}
