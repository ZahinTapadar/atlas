import Foundation

/// Everything the deterministic classifier is allowed to look at.
public struct ClassificationInput: Sendable {
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var domain: String?
    public var pageTitle: String?
    public var state: ActivityState

    public init(bundleID: String?, appName: String?, windowTitle: String?, domain: String?, pageTitle: String?,
                state: ActivityState) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.domain = domain
        self.pageTitle = pageTitle
        self.state = state
    }

    public init(event e: ActivityEvent) {
        self.init(bundleID: e.appBundleID, appName: e.appName, windowTitle: e.windowTitle,
                  domain: e.browser?.domain, pageTitle: e.browser?.title, state: e.state)
    }
}

/// Local, deterministic, LLM-free first-pass classifier.
///
/// Precedence: user corrections > user rules > built-in title-aware rules > built-in app/domain rules.
/// Ambiguous sources (YouTube, IDE with no title, browsers with no tab data) stay low-confidence
/// rather than being promoted to a confident guess.
public struct Classifier: Sendable {
    public var userRules: [ClassificationRule]

    public init(userRules: [ClassificationRule] = []) {
        self.userRules = userRules
    }

    public func classify(_ input: ClassificationInput) -> Classification {
        switch input.state {
        case .systemSleep, .locked, .away:
            return Classification(category: .idle, confidence: 0.95, evidence: [.systemEvent],
                                  explanation: input.state == .away ? "No input beyond the away threshold" : "System not in use")
        case .idle:
            return Classification(category: .idle, confidence: 0.85, evidence: [.idleTimer], explanation: "No input past the idle threshold")
        case .uncertain where input.bundleID == nil && input.domain == nil:
            return .unknown
        default: break
        }

        let title = (input.pageTitle ?? input.windowTitle ?? "").lowercased()
        let bundle = input.bundleID?.lowercased()
        let app = input.appName?.lowercased()
        let domain = input.domain.map(Self.normalizeDomain)

        // 1 & 2: user corrections, then user rules. Most specific (with title condition) first.
        let ordered = userRules.sorted { lhs, rhs in
            let lp = lhs.source == .correction ? 0 : 1, rp = rhs.source == .correction ? 0 : 1
            if lp != rp { return lp < rp }
            if (lhs.titleContains != nil) != (rhs.titleContains != nil) { return lhs.titleContains != nil }
            return lhs.createdAt > rhs.createdAt
        }
        for rule in ordered where Self.matches(rule, bundle: bundle, app: app, domain: domain, title: title) {
            let origin: ClassificationOrigin = rule.source == .correction ? .userConfirmed : .userRule
            return Classification(category: rule.category, confidence: rule.confidence,
                                  evidence: [rule.source == .correction ? .userCorrection : .userRule],
                                  explanation: "Matched your \(rule.source == .correction ? "correction" : "rule") for \(rule.pattern)",
                                  origin: origin)
        }

        var result: Classification
        if let domain {
            result = classifyWeb(domain: domain, title: title, hasTitle: input.pageTitle?.isEmpty == false)
        } else if let bundle {
            result = classifyApp(bundle: bundle, app: app ?? "", title: title, hasTitle: input.windowTitle?.isEmpty == false)
        } else {
            result = .unknown
        }

        // Passive (no input) engagement only stays credible for activities that are naturally passive.
        if input.state == .passive {
            let passiveOK: Set<ActivityCategory> = [.reading, .educationalVideo, .entertainmentVideo, .research]
            if !passiveOK.contains(result.category) {
                result.confidence = min(result.confidence, 0.35)
                result.explanation = (result.explanation ?? "") + "; no recent input"
            }
        }
        if input.state == .uncertain {
            result.confidence = min(result.confidence, 0.4)
        }
        return result
    }

    static func normalizeDomain(_ d: String) -> String {
        var s = d.lowercased()
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasPrefix("m.") { s.removeFirst(2) }
        return s
    }

    static func domainMatches(_ domain: String, _ pattern: String) -> Bool {
        domain == pattern || domain.hasSuffix("." + pattern)
    }

    static func matches(_ rule: ClassificationRule, bundle: String?, app: String?, domain: String?, title: String) -> Bool {
        let primary: Bool
        switch rule.field {
        case .bundleID: primary = bundle == rule.pattern
        case .appName: primary = app == rule.pattern
        case .domain: primary = domain.map { domainMatches($0, rule.pattern) } ?? false
        case .titleContains: primary = !rule.pattern.isEmpty && title.contains(rule.pattern)
        }
        guard primary else { return false }
        if let t = rule.titleContains, !t.isEmpty { return title.contains(t) }
        return true
    }

    // MARK: - Built-in web rules

    private func classifyWeb(domain: String, title: String, hasTitle: Bool) -> Classification {
        let ev: [EvidenceSource] = hasTitle ? [.browserExtension, .builtinRule, .windowTitle] : [.browserExtension, .builtinRule]

        // Video platforms: domain alone is ambiguous. Title decides; without one, stay uncertain.
        if BuiltinRules.videoDomains.contains(where: { Self.domainMatches(domain, $0) }) {
            guard hasTitle else {
                return Classification(category: .entertainmentVideo, confidence: 0.3, evidence: ev,
                                      explanation: "Video site with no title available; content unknown")
            }
            if BuiltinRules.educationalKeywords.contains(where: title.contains) {
                return Classification(category: .educationalVideo, confidence: 0.7, evidence: ev,
                                      explanation: "Video title suggests educational content")
            }
            if BuiltinRules.musicKeywords.contains(where: title.contains) {
                return Classification(category: .breakTime, confidence: 0.45, evidence: ev,
                                      explanation: "Video title suggests music; may be background playback")
            }
            return Classification(category: .entertainmentVideo, confidence: 0.55, evidence: ev,
                                  explanation: "Video with no educational signals in its title")
        }
        if let hit = BuiltinRules.domainRules.first(where: { Self.domainMatches(domain, $0.pattern) }) {
            var conf = hit.confidence
            if hit.category == .research, BuiltinRules.entertainmentKeywords.contains(where: title.contains) { conf -= 0.25 }
            return Classification(category: hit.category, confidence: conf, evidence: ev, explanation: "Known site: \(hit.pattern)")
        }
        if BuiltinRules.searchDomains.contains(where: { Self.domainMatches(domain, $0) }) {
            return Classification(category: .research, confidence: 0.5, evidence: ev, explanation: "Web search")
        }
        if hasTitle, BuiltinRules.codingKeywords.contains(where: title.contains) {
            return Classification(category: .research, confidence: 0.55, evidence: ev, explanation: "Technical page title")
        }
        return Classification(category: .unknown, confidence: 0.2, evidence: ev, explanation: "Unrecognized site")
    }

    // MARK: - Built-in app rules

    private func classifyApp(bundle: String, app: String, title: String, hasTitle: Bool) -> Classification {
        var ev: [EvidenceSource] = [.appIdentity, .builtinRule]
        if hasTitle { ev.append(.windowTitle) }

        if BuiltinRules.browserBundles.contains(bundle) {
            // A browser without tab metadata says nothing about what's on screen.
            return Classification(category: .unknown, confidence: 0.15, evidence: ev,
                                  explanation: "Browser in foreground; no tab data (extension not connected)")
        }
        if BuiltinRules.ideBundles.contains(bundle) {
            if !hasTitle {
                return Classification(category: .coding, confidence: 0.55, evidence: ev,
                                      explanation: "IDE in foreground; window title unavailable")
            }
            if BuiltinRules.docsKeywords.contains(where: title.contains) {
                return Classification(category: .research, confidence: 0.6, evidence: ev, explanation: "IDE showing documentation")
            }
            return Classification(category: .coding, confidence: 0.8, evidence: ev, explanation: "IDE with project window")
        }
        if BuiltinRules.terminalBundles.contains(bundle) {
            return Classification(category: .coding, confidence: hasTitle ? 0.7 : 0.6, evidence: ev, explanation: "Terminal")
        }
        if BuiltinRules.gameLauncherBundles.contains(bundle) {
            return Classification(category: .gaming, confidence: 0.5, evidence: ev,
                                  explanation: "Game launcher in foreground (browsing the store counts too)")
        }
        if BuiltinRules.looksLikeGame(bundle: bundle) {
            return Classification(category: .gaming, confidence: 0.75, evidence: ev, explanation: "Game in foreground")
        }
        if BuiltinRules.readerBundles.contains(bundle) {
            return Classification(category: .reading, confidence: hasTitle ? 0.75 : 0.65, evidence: ev, explanation: "Reader app")
        }
        if let hit = BuiltinRules.appRules[bundle] {
            return Classification(category: hit.0, confidence: hit.1, evidence: ev, explanation: "Known app")
        }
        if bundle.hasPrefix("com.apple.systempreferences") || bundle == "com.apple.finder" {
            return Classification(category: .administrative, confidence: 0.5, evidence: ev, explanation: "System utility")
        }
        return Classification(category: .unknown, confidence: 0.2, evidence: ev,
                              explanation: "Unrecognized app \(app.isEmpty ? bundle : app)")
    }
}

/// Built-in knowledge. Deliberately conservative; users extend it with rules and corrections.
enum BuiltinRules {
    static let browserBundles: Set<String> = [
        "com.apple.safari", "com.google.chrome", "com.google.chrome.canary", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser", "com.vivaldi.vivaldi",
        "com.operasoftware.opera", "app.zen-browser.zen", "org.chromium.chromium",
    ]
    static let ideBundles: Set<String> = [
        "com.microsoft.vscode", "com.microsoft.vscodeinsiders", "com.apple.dt.xcode", "com.todesktop.230313mzl4w4u92",
        "dev.zed.zed", "com.sublimetext.4", "com.jetbrains.intellij", "com.jetbrains.pycharm", "com.jetbrains.webstorm",
        "com.jetbrains.goland", "com.jetbrains.clion", "com.jetbrains.rider", "com.google.android.studio",
        "com.panic.nova", "com.exafunction.windsurf", "com.vscodium",
    ]
    static let terminalBundles: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
    ]
    static let gameLauncherBundles: Set<String> = [
        "com.valvesoftware.steam", "com.epicgames.epicgameslauncher", "com.blizzard.battle.net",
        "com.gog.galaxy", "com.heroicgameslauncher.hgl",
    ]
    static let readerBundles: Set<String> = [
        "com.apple.ibooks", "com.apple.preview", "com.readdle.pdfexpert-mac", "com.adobe.reader", "com.adobe.acrobat.pro",
        "net.sourceforge.skim-app.skim", "com.amazon.lighthouse", "com.kovidgoyal.calibre", "com.readwise.reader",
        "com.highlightsapp.highlights", "com.zotero.zotero",
    ]
    static let appRules: [String: (ActivityCategory, Double)] = [
        "com.tinyspeck.slackmacgap": (.communication, 0.8), "com.hnc.discord": (.communication, 0.65),
        "com.apple.mail": (.communication, 0.8), "com.microsoft.outlook": (.communication, 0.8),
        "com.apple.mobilesms": (.communication, 0.8), "net.whatsapp.whatsapp": (.communication, 0.8),
        "ru.keepcoder.telegram": (.communication, 0.75), "us.zoom.xos": (.communication, 0.85),
        "com.microsoft.teams2": (.communication, 0.85), "com.apple.facetime": (.communication, 0.85),
        "com.apple.ical": (.personalOrganization, 0.8), "com.apple.reminders": (.personalOrganization, 0.8),
        "com.culturedcode.thingsmac": (.personalOrganization, 0.8), "com.todoist.mac.todoist": (.personalOrganization, 0.8),
        "notion.id": (.focusedWork, 0.6), "md.obsidian": (.focusedWork, 0.6), "com.apple.notes": (.focusedWork, 0.55),
        "com.apple.iwork.pages": (.focusedWork, 0.7), "com.apple.iwork.numbers": (.focusedWork, 0.7),
        "com.apple.iwork.keynote": (.focusedWork, 0.7), "com.microsoft.word": (.focusedWork, 0.7),
        "com.microsoft.excel": (.focusedWork, 0.7), "com.microsoft.powerpoint": (.focusedWork, 0.7),
        "com.figma.desktop": (.focusedWork, 0.7), "com.github.githubclient": (.coding, 0.75),
        "com.fournova.tower3": (.coding, 0.75), "com.docker.docker": (.coding, 0.6),
        "com.postmanlabs.mac": (.coding, 0.7), "com.spotify.client": (.breakTime, 0.3), "com.apple.music": (.breakTime, 0.3),
        "com.apple.tv": (.entertainmentVideo, 0.75), "com.netflix.netflix": (.entertainmentVideo, 0.85),
        "com.apple.systempreferences": (.administrative, 0.6), "com.apple.appstore": (.administrative, 0.4),
        "com.apple.activitymonitor": (.administrative, 0.5),
    ]
    static let gameBundlePrefixes = ["com.valvesoftware.", "com.riotgames.", "com.blizzard.", "com.mojang.",
                                     "com.feralinteractive.", "com.aspyr.", "com.paradoxinteractive.", "unity."]
    static func looksLikeGame(bundle: String) -> Bool {
        guard !gameLauncherBundles.contains(bundle) else { return false }
        return gameBundlePrefixes.contains(where: bundle.hasPrefix) || bundle.contains(".steamapps.")
    }

    static let videoDomains = ["youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "dailymotion.com", "bilibili.com"]
    static let searchDomains = ["google.com", "duckduckgo.com", "bing.com", "kagi.com", "search.brave.com", "perplexity.ai"]
    static let domainRules: [(pattern: String, category: ActivityCategory, confidence: Double)] = [
        ("instagram.com", .socialMedia, 0.85), ("facebook.com", .socialMedia, 0.8), ("x.com", .socialMedia, 0.8),
        ("twitter.com", .socialMedia, 0.8), ("tiktok.com", .socialMedia, 0.85), ("threads.net", .socialMedia, 0.8),
        ("bsky.app", .socialMedia, 0.8), ("linkedin.com", .socialMedia, 0.55), ("pinterest.com", .socialMedia, 0.75),
        ("reddit.com", .socialMedia, 0.55), ("news.ycombinator.com", .socialMedia, 0.45),
        ("netflix.com", .entertainmentVideo, 0.85), ("disneyplus.com", .entertainmentVideo, 0.85),
        ("primevideo.com", .entertainmentVideo, 0.8), ("hulu.com", .entertainmentVideo, 0.85),
        ("github.com", .coding, 0.7), ("gitlab.com", .coding, 0.7), ("stackoverflow.com", .research, 0.75),
        ("developer.apple.com", .research, 0.8), ("developer.mozilla.org", .research, 0.85), ("docs.python.org", .research, 0.85),
        ("docs.rs", .research, 0.85), ("readthedocs.io", .research, 0.8), ("arxiv.org", .research, 0.8),
        ("wikipedia.org", .research, 0.6), ("medium.com", .research, 0.45), ("dev.to", .research, 0.55),
        ("coursera.org", .research, 0.8), ("edx.org", .research, 0.8), ("khanacademy.org", .research, 0.8),
        ("udemy.com", .research, 0.75), ("leetcode.com", .coding, 0.7), ("replit.com", .coding, 0.75),
        ("codesandbox.io", .coding, 0.75), ("vercel.com", .coding, 0.6), ("claude.ai", .research, 0.5),
        ("chatgpt.com", .research, 0.5), ("mail.google.com", .communication, 0.8), ("outlook.live.com", .communication, 0.8),
        ("slack.com", .communication, 0.8), ("discord.com", .communication, 0.6), ("web.whatsapp.com", .communication, 0.8),
        ("calendar.google.com", .personalOrganization, 0.8), ("notion.so", .focusedWork, 0.55),
        ("docs.google.com", .focusedWork, 0.65), ("figma.com", .focusedWork, 0.65),
        ("nytimes.com", .research, 0.4), ("bbc.com", .research, 0.4), ("theguardian.com", .research, 0.4),
        ("goodreads.com", .reading, 0.5), ("gutenberg.org", .reading, 0.75), ("kindle.amazon.com", .reading, 0.8),
        ("read.amazon.com", .reading, 0.8), ("royalroad.com", .reading, 0.7), ("archiveofourown.org", .reading, 0.7),
        ("store.steampowered.com", .gaming, 0.5), ("chess.com", .gaming, 0.8), ("lichess.org", .gaming, 0.8),
        ("poki.com", .gaming, 0.85), ("itch.io", .gaming, 0.6),
    ]
    static let educationalKeywords = ["lecture", "tutorial", "course", "lesson", "explained", "how to", "introduction to",
                                      "talk", "conference", "wwdc", "mit ", "stanford", "crash course", "documentary",
                                      "programming", "math", "physics", "chapter", "learn"]
    static let musicKeywords = ["official audio", "official music video", "lyrics", "lofi", "lo-fi", "playlist", " mix", "album"]
    static let entertainmentKeywords = ["funny", "meme", "prank", "reaction", "trailer"]
    static let codingKeywords = ["swift", "python", "javascript", "typescript", "rust", "api", "error", "exception",
                                 "documentation", "docs", "reference", "github", "stack overflow", "how to"]
    static let docsKeywords = ["documentation", "developer documentation", "quick help"]
}
