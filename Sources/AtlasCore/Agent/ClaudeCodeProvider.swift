import Foundation

/// Runs analyses through the Claude Code CLI (`claude -p`), the runtime the Claude Agent SDK wraps,
/// authenticated with the user's Claude subscription instead of API credits.
///
/// Billing safety: the CLI is launched with every API-credential variable removed from its environment,
/// and each run is preceded by `claude auth status`; if the CLI is not signed in through claude.ai
/// (a subscription), the analysis is refused rather than silently billed to an API key.
public struct ClaudeCodeProvider: AnalysisProvider {
    public let identifier = "claude-code"
    let executableOverride: String?
    let timeout: TimeInterval

    /// Environment variables that would switch the CLI to pay-per-use API billing or another provider.
    static let scrubbedEnvironment: Set<String> = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_PROFILE",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_IDENTITY_TOKEN", "ANTHROPIC_IDENTITY_TOKEN_FILE",
    ]

    public init(executablePath: String? = nil, timeout: TimeInterval = 600) {
        self.executableOverride = executablePath.flatMap { $0.isEmpty ? nil : $0 }
        self.timeout = timeout
    }

    /// GUI apps don't inherit the shell's PATH, so look in the usual install locations.
    public static func locateExecutable(override: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [override, "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct AuthStatus: Sendable, Equatable {
        public var loggedIn: Bool
        public var method: String
        public var isSubscription: Bool { loggedIn && method == "claude.ai" }
    }

    public func authStatus() async -> AuthStatus? {
        guard let exe = Self.locateExecutable(override: executableOverride),
              let out = try? await Self.run(exe, ["auth", "status"], stdin: nil, timeout: 30),
              let obj = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else { return nil }
        return AuthStatus(loggedIn: obj["loggedIn"] as? Bool ?? false, method: obj["authMethod"] as? String ?? "unknown")
    }

    public func isConfigured() async -> Bool { await authStatus()?.isSubscription ?? false }

    func arguments(for r: AnalysisRequest) -> [String] {
        [
            "-p", "--output-format", "json",
            "--json-schema", r.schemaJSON,
            "--system-prompt", r.system,
            "--model", r.model,
            "--effort", r.effort,
            // A pure analysis call: no tools, no MCP servers, no user hooks/plugins/CLAUDE.md, no saved session.
            "--tools", "",
            "--strict-mcp-config",
            "--safe-mode",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]
    }

    public func analyze(_ r: AnalysisRequest) async throws -> AnalysisResponse {
        guard let exe = Self.locateExecutable(override: executableOverride) else {
            throw ProviderError.notConfigured("Claude Code CLI not found. Install it and run `claude auth login`.")
        }
        guard let auth = await authStatus() else {
            throw ProviderError.notConfigured("Could not read Claude Code sign-in status")
        }
        guard auth.isSubscription else {
            throw ProviderError.notConfigured(auth.loggedIn
                ? "Claude Code is signed in with \(auth.method), not a Claude subscription. Run `claude auth login` and choose your Claude account."
                : "Claude Code is not signed in. Run `claude auth login` with your Claude subscription.")
        }

        let out: ProcessOutput
        do {
            out = try await Self.run(exe, arguments(for: r), stdin: Data(r.userContent.utf8), timeout: timeout)
        } catch ProcessFailure.timedOut {
            throw ProviderError.retryable("Claude Code timed out after \(Int(timeout)) s")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else {
            let tail = String(decoding: out.stderr.suffix(300), as: UTF8.self)
            throw ProviderError.retryable("Claude Code exited \(out.status) without JSON: \(AtlasLog.redact(tail))")
        }

        if obj["is_error"] as? Bool == true || obj["subtype"] as? String != "success" {
            let status = obj["api_error_status"] as? Int
            let message = (obj["result"] as? String).map { String($0.prefix(300)) } ?? (obj["subtype"] as? String ?? "error")
            switch status {
            case 401, 403: throw ProviderError.permanent("Claude Code authentication failed. Run `claude auth login`.")
            case 400, 404, 413, 422: throw ProviderError.permanent(message)
            case 429: throw ProviderError.retryable("Claude plan usage limit reached; will retry later")
            default:
                if obj["stop_reason"] as? String == "refusal" { throw ProviderError.refused(message) }
                throw ProviderError.retryable(message)
            }
        }

        let json: String
        if let structured = obj["structured_output"], JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys]) {
            json = String(decoding: data, as: UTF8.self)
        } else if let text = obj["result"] as? String, !text.isEmpty {
            json = text
        } else {
            throw ProviderError.invalidResponse("No structured output in Claude Code result")
        }

        let usage = obj["usage"] as? [String: Any]
        let model = (obj["modelUsage"] as? [String: Any])?.keys.sorted().first ?? r.model
        // The CLI reports uncached input separately from cache writes/reads; total them for honest usage figures.
        let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
            .compactMap { usage?[$0] as? Int }.reduce(0, +)
        return AnalysisResponse(json: json, model: model, inputTokens: usage == nil ? nil : input,
                                outputTokens: usage?["output_tokens"] as? Int,
                                cacheReadTokens: usage?["cache_read_input_tokens"] as? Int)
    }

    // MARK: - Agent runs

    public struct AgentRun: Sendable {
        public var ok: Bool
        public var text: String
    }

    /// Runs one non-interactive Claude Code session with only `allowedTools` permitted (used for a check-in
    /// requested from ATLAS). Same billing guard as analyses: subscription sign-in only, API keys scrubbed.
    public func runAgent(prompt: String, allowedTools: [String], timeout: TimeInterval = 900) async throws -> AgentRun {
        guard let exe = Self.locateExecutable(override: executableOverride) else {
            throw ProviderError.notConfigured("Claude Code CLI not found. Install it and run `claude auth login`.")
        }
        guard let auth = await authStatus(), auth.isSubscription else {
            throw ProviderError.notConfigured("Claude Code isn't signed in with a Claude subscription. Run `claude auth login`.")
        }
        let args = ["-p", "--output-format", "json", "--allowedTools", allowedTools.joined(separator: " "),
                    "--no-session-persistence"]
        let out = try await Self.run(exe, args, stdin: Data(prompt.utf8), timeout: timeout)
        guard let obj = try? JSONSerialization.jsonObject(with: out.stdout) as? [String: Any] else {
            return AgentRun(ok: false, text: AtlasLog.redact(String(decoding: out.stderr.suffix(300), as: UTF8.self)))
        }
        let ok = obj["is_error"] as? Bool != true && obj["subtype"] as? String == "success"
        return AgentRun(ok: ok, text: obj["result"] as? String ?? "")
    }

    // MARK: - Process plumbing

    struct ProcessOutput: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: Data
    }

    enum ProcessFailure: Error { case timedOut }

    static func run(_ exe: String, _ args: [String], stdin: Data?, timeout: TimeInterval) async throws -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment.filter { !scrubbedEnvironment.contains($0.key) }
        // Make sure the CLI's own helpers (node, git) resolve when launched from a GUI app.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        p.environment = env
        // Empty scratch directory: nothing from any project is in scope.
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        p.currentDirectoryURL = cwd

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = inPipe

        // Drain pipes concurrently so a large result can't deadlock on a full pipe buffer.
        let outTask = Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }
        let errTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }
        try p.run()
        if let stdin { inPipe.fileHandleForWriting.write(stdin) }
        try? inPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                _ = await outTask.value
                _ = await errTask.value
                throw ProcessFailure.timedOut
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return ProcessOutput(status: p.terminationStatus, stdout: await outTask.value, stderr: await errTask.value)
    }
}

public enum AgentBackend: String, Codable, CaseIterable, Sendable {
    /// Claude Code CLI signed in with a Claude subscription (default; no API credits).
    case claudeSubscription = "claude_subscription"
    /// Anthropic API key from Keychain, billed per token. Only used when explicitly selected.
    case anthropicAPI = "anthropic_api"

    public var displayName: String {
        switch self {
        case .claudeSubscription: "Claude subscription (via Claude Code)"
        case .anthropicAPI: "Anthropic API key (pay per use)"
        }
    }
}

/// Dispatches to the backend the user selected, re-reading the choice on every call.
/// There is deliberately no fallback between backends: if the subscription path is unavailable,
/// windows stay queued rather than being billed to an API key.
public struct BackendSelector: AnalysisProvider {
    public let identifier = "selector"
    let resolve: @Sendable () async -> AnalysisProvider

    public init(resolve: @escaping @Sendable () async -> AnalysisProvider) { self.resolve = resolve }

    public func isConfigured() async -> Bool { await resolve().isConfigured() }
    public func analyze(_ request: AnalysisRequest) async throws -> AnalysisResponse { try await resolve().analyze(request) }
}
