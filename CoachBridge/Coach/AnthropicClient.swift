import Foundation

struct ChatMessage: Identifiable, Sendable, Equatable {
    enum Role: String, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String

    init(role: Role, text: String) {
        id = UUID()
        self.role = role
        self.text = text
    }
}

/// Streams replies from the Anthropic Messages API over plain URLSession (no SDK).
struct AnthropicClient: LLMClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"

    enum APIError: LocalizedError {
        case missingKey
        case http(Int, String)
        case stream(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: return "Add your Anthropic API key in Settings."
            case .http(401, _): return "The API key was rejected. Check it in Settings."
            case .http(let code, let msg): return "Claude API error \(code): \(msg)"
            case .stream(let msg): return "Claude API error: \(msg)"
            }
        }
    }

    let apiKey: String
    var model: String
    var maxTokens = 1500

    /// What a streamed reply can produce: text as it arrives, and a tool call once complete.
    enum StreamEvent: Sendable, Equatable {
        case text(String)
        case toolUse(name: String, json: String)
    }

    /// Streams a reply. With `tools`, Claude may call one; its input arrives as `toolUse`.
    func stream(system: String, messages: [ChatMessage], tools: [[String: Any]] = []) -> AsyncThrowingStream<StreamEvent, Error> {
        let request: URLRequest
        do {
            request = try makeRequest(system: system, messages: messages, tools: tools)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let feature = UsageContext.feature, model = self.model
        return AsyncThrowingStream { continuation in
            let task = Task {
                var usage = TokenUsage.zero
                // Recorded however the stream ends: tokens used before a cancel are still billed.
                defer {
                    if usage != .zero { UsageMeter.record(usage, feature: feature, provider: "anthropic", model: model) }
                }
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw APIError.stream("no response") }
                    guard http.statusCode == 200 else {
                        var data = Data()
                        for try await b in bytes { data.append(b) }
                        throw APIError.http(http.statusCode, Self.errorMessage(data) ?? "no details")
                    }
                    var toolName: String?
                    var toolJSON = ""
                    for try await line in bytes.lines {
                        if let u = UsageParsing.anthropicStream(line: line) {
                            if let i = u.input { usage.input = i }
                            if let o = u.output { usage.output = o }
                        }
                        switch Self.raw(line: line) {
                        case .text(let t):
                            continuation.yield(.text(t))
                        case .toolStart(let name):
                            toolName = name
                            toolJSON = ""
                        case .toolJSON(let part):
                            toolJSON += part
                        case .blockStop:
                            if let n = toolName {
                                continuation.yield(.toolUse(name: n, json: toolJSON))
                                toolName = nil
                            }
                        case .error(let m):
                            throw APIError.stream(m)
                        case .stop:
                            continuation.finish()
                            return
                        case .none:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func makeRequest(system: String, messages: [ChatMessage], tools: [[String: Any]] = []) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw APIError.missingKey }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if !tools.isEmpty { body["tools"] = tools }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Forced tool call (structured output)

    /// Sends one user message with a single tool the model must call, and returns that
    /// tool's input as JSON data.
    func runTool(system: String, user: String, tool: [String: Any]) async throws -> Data {
        guard !apiKey.isEmpty else { throw APIError.missingKey }
        guard let name = tool["name"] as? String else { throw APIError.stream("tool has no name") }
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": name],
            "messages": [["role": "user", "content": user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.stream("no response") }
        guard http.statusCode == 200 else {
            throw APIError.http(http.statusCode, Self.errorMessage(data) ?? "no details")
        }
        // Before parsing: a reply the app can't use was still paid for.
        if let usage = UsageParsing.anthropic(response: data) {
            UsageMeter.record(usage, feature: UsageContext.feature, provider: "anthropic", model: model)
        }
        return try Self.toolInput(from: data, name: name)
    }

    static func toolInput(from data: Data, name: String) throws -> Data {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]],
              let block = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == name }),
              let input = block["input"] else {
            throw APIError.stream("Claude didn't return a plan update")
        }
        if (obj["stop_reason"] as? String) == "max_tokens" {
            throw APIError.stream("The update was cut off. Try again.")
        }
        return try JSONSerialization.data(withJSONObject: input)
    }

    // MARK: - SSE parsing (pure, unit-tested)

    enum Event: Equatable { case text(String), error(String), stop, none }

    /// Every server-sent event the chat cares about, including streamed tool input.
    enum Raw: Equatable { case text(String), toolStart(String), toolJSON(String), blockStop, error(String), stop, none }

    static func raw(line: String) -> Raw {
        guard line.hasPrefix("data:") else { return .none }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        switch obj["type"] as? String {
        case "content_block_start":
            if let block = obj["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
               let name = block["name"] as? String { return .toolStart(name) }
            return .none
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any] else { return .none }
            if delta["type"] as? String == "text_delta", let t = delta["text"] as? String { return .text(t) }
            if delta["type"] as? String == "input_json_delta", let p = delta["partial_json"] as? String { return .toolJSON(p) }
            return .none
        case "content_block_stop":
            return .blockStop
        case "error":
            return .error((obj["error"] as? [String: Any])?["message"] as? String ?? "unknown error")
        case "message_stop":
            return .stop
        default:
            return .none
        }
    }

    static func parse(line: String) -> Event {
        guard line.hasPrefix("data:") else { return .none }
        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .none }
        switch obj["type"] as? String {
        case "content_block_delta":
            if let delta = obj["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String { return .text(text) }
            return .none
        case "error":
            return .error((obj["error"] as? [String: Any])?["message"] as? String ?? "unknown error")
        case "message_stop":
            return .stop
        default:
            return .none
        }
    }

    static func errorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (obj["error"] as? [String: Any])?["message"] as? String
    }
}
