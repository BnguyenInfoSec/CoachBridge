import Foundation

/// Everything the app needs from a model: stream a reply (optionally calling a tool), and run a
/// forced tool call for the weekly plan update. `AnthropicClient` and `OpenAIClient` both
/// implement it, and a hosted backend can implement it later without touching the app above.
protocol LLMClient: Sendable {
    func stream(system: String, messages: [ChatMessage], tools: [[String: Any]]) -> AsyncThrowingStream<AnthropicClient.StreamEvent, Error>
    /// Forces one call to `tool` and returns its arguments as JSON.
    func runTool(system: String, user: String, tool: [String: Any]) async throws -> Data
}

/// Who serves the model.
enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic
    case openai
    /// A server you run, holding the key for a group of people. Not wired up yet; see
    /// `HostedClient` for the shape it expects.
    case hosted

    static let key = "coach.provider"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI"
        case .hosted: return "Shared server"
        }
    }

    /// Where the key is kept. Each provider gets its own Keychain item, so switching back and
    /// forth doesn't make you re-paste.
    var keychainAccount: String {
        switch self {
        case .anthropic: return AppSettings.apiKeyAccount
        case .openai: return "openai-api-key"
        case .hosted: return "hosted-access-token"
        }
    }

    var keyPrompt: String {
        switch self {
        case .anthropic: return "sk-ant-…"
        case .openai: return "sk-…"
        case .hosted: return "Access token from whoever runs the server"
        }
    }

    var consoleURL: String {
        switch self {
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai: return "https://platform.openai.com/api-keys"
        case .hosted: return ""
        }
    }

    /// Models offered in Settings. Free text is still allowed, so a new model works the day
    /// it ships without an app update.
    var models: [String] {
        switch self {
        case .anthropic: return ["claude-haiku-5", "claude-sonnet-5", "claude-opus-5"]
        case .openai: return ["gpt-5-mini", "gpt-5"]
        case .hosted: return ["default"]
        }
    }

    var defaultModel: String { models.count > 1 ? models[1] : models[0] }

    /// Rough per-message cost guidance for the Settings screen. Deliberately vague — prices move.
    var costNote: String {
        switch self {
        case .anthropic, .openai:
            return "You're billed by your own account. A chat message with the Health summary attached runs roughly a cent on a mid-tier model, and a few times that on the largest one. Set a spend limit in the provider's console."
        case .hosted:
            return "Billed to whoever runs the server, not to you."
        }
    }
}

/// Builds the client for whatever the athlete has chosen. One place decides, so adding a
/// provider doesn't mean hunting through the app.
enum LLMFactory {
    static func current(maxTokens: Int) -> (client: LLMClient, provider: LLMProvider, model: String)? {
        let defaults = UserDefaults.standard
        let provider = LLMProvider(rawValue: defaults.string(forKey: LLMProvider.key) ?? "") ?? .anthropic
        let model = defaults.string(forKey: AppSettings.modelKey)
            .flatMap { PromptSafety.isPlausibleModelName($0) ? $0 : nil } ?? provider.defaultModel
        guard let secret = Keychain.get(account: provider.keychainAccount), !secret.isEmpty else { return nil }

        switch provider {
        case .anthropic:
            return (AnthropicClient(apiKey: secret, model: model, maxTokens: maxTokens), provider, model)
        case .openai:
            return (OpenAIClient(apiKey: secret, model: model, maxTokens: maxTokens), provider, model)
        case .hosted:
            let base = defaults.string(forKey: AppSettings.hostedURLKey) ?? ""
            // https only: the access token rides on every request.
            guard let url = PromptSafety.webURL(base) else { return nil }
            return (HostedClient(baseURL: url, token: secret, model: model, maxTokens: maxTokens), provider, model)
        }
    }

    /// Whether the chosen provider has what it needs to run.
    static var isConfigured: Bool { current(maxTokens: 1) != nil }

    /// Why nothing can run, naming the provider and what's missing *on this iPhone*. A missing
    /// key used to read the same as a fresh install, and always said "Anthropic" — even with
    /// OpenAI chosen, or after a reinstall wiped the Keychain.
    static func missingSetupMessage(for feature: String) -> String {
        let defaults = UserDefaults.standard
        let provider = LLMProvider(rawValue: defaults.string(forKey: LLMProvider.key) ?? "") ?? .anthropic
        if provider == .hosted, (defaults.string(forKey: AppSettings.hostedURLKey) ?? "").isEmpty {
            return "Add the shared server's address in Settings → Model provider to \(feature)."
        }
        let what = provider == .hosted ? "access token for the shared server" : "\(provider.label) API key"
        return "No \(what) is saved on this iPhone. Add it in Settings → Model provider to \(feature). "
            + "Keys stay on the phone they were added on, and deleting the app removes them."
    }
}

/// Checks a key before it's saved, with the provider's free model-list endpoint: nothing is
/// generated, so it costs nothing. The key goes only to that provider, over an ephemeral
/// session that keeps no cache or cookies.
enum KeyTester {
    enum Result: Equatable {
        case valid, rejected, unreachable(String)

        var message: String {
            switch self {
            case .valid: return "The key works."
            case .rejected: return "The provider rejected this key. Check it was copied in full and hasn't been revoked."
            case .unreachable(let why): return "Couldn't check the key: \(why)"
            }
        }
    }

    static func request(provider: LLMProvider, key: String) -> URLRequest? {
        switch provider {
        case .anthropic:
            var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            r.setValue(key, forHTTPHeaderField: "x-api-key")
            r.setValue(AnthropicClient.apiVersion, forHTTPHeaderField: "anthropic-version")
            return r
        case .openai:
            var r = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            return r
        case .hosted:
            return nil                                        // the server's own business
        }
    }

    static func test(provider: LLMProvider, key: String) async -> Result {
        guard var req = request(provider: provider, key: key.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .unreachable("a shared server's token can only be checked by sending a message.")
        }
        req.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(for: req)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return .valid
            case 401, 403: return .rejected
            case let code: return .unreachable("the provider answered \(code).")
            }
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}

// MARK: - OpenAI

/// Chat Completions with SSE streaming and function calling. Kept deliberately close in shape to
/// `AnthropicClient` so the two can be read side by side.
struct OpenAIClient: LLMClient {
    let apiKey: String
    var model: String = "gpt-5-mini"
    var maxTokens: Int = 1500
    var baseURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    func stream(system: String, messages: [ChatMessage], tools: [[String: Any]] = []) -> AsyncThrowingStream<AnthropicClient.StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(system: system, messages: messages, tools: tools, stream: true)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try Self.check(response)

                    var toolName: String?
                    var toolJSON = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choice = (root["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any] else { continue }

                        if let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        if let calls = delta["tool_calls"] as? [[String: Any]], let call = calls.first {
                            if let fn = call["function"] as? [String: Any] {
                                if let name = fn["name"] as? String, !name.isEmpty { toolName = name }
                                if let part = fn["arguments"] as? String { toolJSON += part }
                            }
                        }
                        if let reason = choice["finish_reason"] as? String, reason == "tool_calls",
                           let name = toolName {
                            continuation.yield(.toolUse(name: name, json: toolJSON))
                            toolName = nil
                            toolJSON = ""
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

    func runTool(system: String, user: String, tool: [String: Any]) async throws -> Data {
        var request = try makeRequest(system: system,
                                      messages: [ChatMessage(role: .user, text: user)],
                                      tools: [tool], stream: false)
        // Force the call, the same contract as Anthropic's tool_choice.
        try forceTool(named: tool["name"] as? String ?? "", in: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let call = (message["tool_calls"] as? [[String: Any]])?.first,
              let fn = call["function"] as? [String: Any],
              let args = fn["arguments"] as? String else {
            throw AnthropicClient.APIError.stream("The model didn't return a \(tool["name"] as? String ?? "tool") call.")
        }
        return Data(args.utf8)
    }

    // MARK: Request building

    func makeRequest(system: String, messages: [ChatMessage], tools: [[String: Any]], stream: Bool) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": maxTokens,
            "messages": [["role": "system", "content": system]]
                + messages.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        if stream { body["stream"] = true }
        if !tools.isEmpty {
            // Anthropic's tool shape → OpenAI's function shape.
            body["tools"] = tools.map { t -> [String: Any] in
                ["type": "function",
                 "function": ["name": t["name"] ?? "",
                              "description": t["description"] ?? "",
                              "parameters": t["input_schema"] ?? [:]]]
            }
        }
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func forceTool(named name: String, in request: inout URLRequest) throws {
        guard let data = request.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        body["tool_choice"] = ["type": "function", "function": ["name": name]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    static func check(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = data.flatMap { d -> String? in
                (try? JSONSerialization.jsonObject(with: d) as? [String: Any])
                    .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            } ?? ""
            throw AnthropicClient.APIError.http(http.statusCode, message)
        }
    }
}

// MARK: - Hosted (the seam for a shared key)

/// Talks to a server you run, which holds one API key for a group and forwards to whichever
/// model it likes. The app sends a per-person access token instead of an API key, so nobody's
/// key ships in the binary and you can rate-limit or cut someone off server-side.
///
/// The server is expected to expose, under `baseURL`:
///   POST /chat  — same JSON as this app sends, replying with Anthropic-style SSE
///   POST /tool  — forced tool call, replying with the tool's arguments as JSON
///
/// Nothing here is live yet. See the README for what building that server involves.
struct HostedClient: LLMClient {
    let baseURL: URL
    let token: String
    var model: String
    var maxTokens: Int

    func stream(system: String, messages: [ChatMessage], tools: [[String: Any]] = []) -> AsyncThrowingStream<AnthropicClient.StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(path: "chat", body: [
                        "model": model, "max_tokens": maxTokens, "system": system,
                        "messages": messages.map { ["role": $0.role.rawValue, "content": $0.text] },
                        "tools": tools,
                    ])
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    try OpenAIClient.check(response)
                    // The server speaks Anthropic's event format, so the existing parser applies.
                    var toolName: String?
                    var toolJSON = ""
                    for try await line in bytes.lines {
                        switch AnthropicClient.raw(line: line) {
                        case .text(let t): continuation.yield(.text(t))
                        case .toolStart(let name): toolName = name; toolJSON = ""
                        case .toolJSON(let part): toolJSON += part
                        case .blockStop:
                            if let name = toolName { continuation.yield(.toolUse(name: name, json: toolJSON)) }
                            toolName = nil
                        case .error(let m): throw AnthropicClient.APIError.stream(m)
                        case .stop, .none: continue
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

    func runTool(system: String, user: String, tool: [String: Any]) async throws -> Data {
        let request = try makeRequest(path: "tool", body: [
            "model": model, "max_tokens": maxTokens, "system": system, "user": user, "tool": tool,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        try OpenAIClient.check(response, data: data)
        return data
    }

    private func makeRequest(path: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
