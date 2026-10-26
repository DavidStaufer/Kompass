import Foundation

// MARK: - Chat-Modelle

struct AIToolCall: Codable, Hashable {
    var id: String
    var name: String
    var arguments: String
}

enum ChatRole: String, Codable { case user, assistant, tool }

struct ChatAttachment: Codable, Hashable {
    enum Kind: String, Codable { case quiz, doc, cards, plan, module, deadline, view }
    var kind: Kind
    var id: String
    var label: String
}

struct AIMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var reasoning: String?
    var toolCalls: [AIToolCall]?
    var toolCallID: String?
    var toolName: String?
    var summary: String?
    var isError: Bool?
    var attachment: ChatAttachment?
    var createdAt = Date()
}

struct ChatThread: Codable {
    var messages: [AIMessage] = []
    var updatedAt = Date()
}

// MARK: - Client

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct StreamResult {
    var content = ""
    var reasoning = ""
    var toolCalls: [AIToolCall] = []
    var finishReason: String?
    var pendingToolNames: [String] = []
}

/// Minimaler Client für die DeepSeek-API (OpenAI-kompatibel) mit Streaming und Tool-Calls.
struct DeepSeekClient {
    let apiKey: String
    let baseURL: String
    let model: String

    static func fromSettings(_ prefs: Preferences) -> DeepSeekClient? {
        guard let key = Secrets.deepSeekKey?.trimmed, !key.isEmpty else { return nil }
        return DeepSeekClient(apiKey: key, baseURL: prefs.aiBaseURL.trimmed.isEmpty ? "https://api.deepseek.com" : prefs.aiBaseURL.trimmed,
                              model: prefs.aiModel.trimmed.isEmpty ? "deepseek-chat" : prefs.aiModel.trimmed)
    }

    private var endpoint: URL {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/chat/completions") ?? URL(string: "https://api.deepseek.com/chat/completions")!
    }

    func stream(messages: [[String: Any]],
                tools: [[String: Any]]? = nil,
                jsonMode: Bool = false,
                temperature: Double? = nil,
                maxTokens: Int = 8000,
                onUpdate: @escaping @MainActor (StreamResult) -> Void) async throws -> StreamResult {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": maxTokens
        ]
        if let tools, !tools.isEmpty { body["tools"] = tools }
        if jsonMode { body["response_format"] = ["type": "json_object"] }
        if let temperature, !model.contains("reasoner") { body["temperature"] = temperature }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw AIError(message: "Keine Antwort vom Server.") }
        if http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
            throw Self.mapError(status: http.statusCode, body: text)
        }

        var result = StreamResult()
        var acc: [Int: (id: String, name: String, args: String)] = [:]
        var lastEmit = Date.distantPast
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let err = obj["error"] as? [String: Any] {
                throw AIError(message: (err["message"] as? String) ?? "Unbekannter Fehler der KI.")
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let delta = choice["delta"] as? [String: Any] {
                if let c = delta["content"] as? String { result.content += c }
                if let r = delta["reasoning_content"] as? String { result.reasoning += r }
                if let calls = delta["tool_calls"] as? [[String: Any]] {
                    for call in calls {
                        let idx = call["index"] as? Int ?? 0
                        var a = acc[idx] ?? (id: "", name: "", args: "")
                        if let id = call["id"] as? String, !id.isEmpty { a.id = id }
                        if let fn = call["function"] as? [String: Any] {
                            if let n = fn["name"] as? String { a.name += n }
                            if let args = fn["arguments"] as? String { a.args += args }
                        }
                        acc[idx] = a
                    }
                    result.pendingToolNames = acc.sorted { $0.key < $1.key }.map(\.value.name)
                }
            }
            if let fr = choice["finish_reason"] as? String { result.finishReason = fr }
            if Date().timeIntervalSince(lastEmit) > 0.05 {
                lastEmit = Date()
                let snapshot = result
                await onUpdate(snapshot)
            }
        }
        result.toolCalls = acc.sorted { $0.key < $1.key }.map { k, v in
            AIToolCall(id: v.id.isEmpty ? "call_\(k)_\(UUID().uuidString.prefix(6))" : v.id, name: v.name, arguments: v.args.isEmpty ? "{}" : v.args)
        }
        let final = result
        await onUpdate(final)
        return result
    }

    /// Einfache Anfrage ohne Tools – liefert den gesamten Text.
    func complete(system: String, user: String, jsonMode: Bool = false, temperature: Double = 0.5, maxTokens: Int = 8000,
                  onUpdate: @escaping @MainActor (StreamResult) -> Void = { _ in }) async throws -> String {
        let msgs: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": user]]
        let r = try await stream(messages: msgs, jsonMode: jsonMode, temperature: temperature, maxTokens: maxTokens, onUpdate: onUpdate)
        if r.finishReason == "length" && jsonMode {
            throw AIError(message: "Die Antwort war zu lang und wurde abgeschnitten. Versuch es mit weniger Fragen oder weniger Material.")
        }
        return r.content
    }

    /// Prüft Schlüssel und Erreichbarkeit.
    func test() async throws -> String {
        let r = try await complete(system: "Antworte mit genau einem Wort.", user: "Sag 'Bereit'.", temperature: 0, maxTokens: 10)
        return r.trimmed
    }

    static func mapError(status: Int, body: String) -> AIError {
        var detail = ""
        if let data = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { detail = msg }
        switch status {
        case 401: return AIError(message: "Der DeepSeek-API-Key ist ungültig. Bitte in den Einstellungen → KI prüfen.")
        case 402: return AIError(message: "Dein DeepSeek-Guthaben ist aufgebraucht. Auf platform.deepseek.com kannst du es aufladen.")
        case 429: return AIError(message: "Zu viele Anfragen gleichzeitig – warte einen Moment und versuch es erneut.")
        case 500, 502, 503: return AIError(message: "DeepSeek ist gerade überlastet. Versuch es gleich noch einmal.")
        case 400, 422: return AIError(message: "Die KI hat die Anfrage abgelehnt\(detail.isEmpty ? "" : ": \(detail)").")
        default: return AIError(message: "Fehler \(status)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }
}

/// Holt JSON aus einer KI-Antwort, auch wenn sie in ```json … ``` steckt.
enum JSONExtract {
    static func object(_ text: String) -> [String: Any]? {
        var s = text.trimmed
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "").trimmed
        }
        if let d = s.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b {
            let sub = String(s[a...b])
            if let d = sub.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { return o }
        }
        return nil
    }
}
