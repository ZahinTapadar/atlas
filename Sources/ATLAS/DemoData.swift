import AppKit
import AtlasCore
import Foundation

/// Synthetic sample day for `--demo` launches (screenshots, previews). Never touches the real database.
enum DemoData {
    static var isEnabled: Bool { CommandLine.arguments.contains("--demo") }

    /// `--section checkins` etc. opens a screen directly (screenshots).
    static var startSection: AppSection? {
        guard isEnabled, let i = CommandLine.arguments.firstIndex(of: "--section"), i + 1 < CommandLine.arguments.count else { return nil }
        return AppSection.allCases.first { $0.rawValue.lowercased().replacingOccurrences(of: "-", with: "") == CommandLine.arguments[i + 1] }
    }

    /// Fixed window size and optional forced appearance, so captures are reproducible.
    @MainActor static func prepareWindow() {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
                  let screen = w.screen?.visibleFrame else { return }
            let size = NSSize(width: 1440, height: 900)
            w.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        }
    }

    private struct Seg {
        var minutes: Double
        var app: String
        var bundle: String
        var title: String?
        var domain: String? = nil
        var category: ActivityCategory
        var confidence: Double = 0.8
        var state: ActivityState = .active
    }

    /// Synthetic check-ins for the six earlier days, in the product's voice: verdict, minutes, next step.
    private static let pastCheckins: [[(String, String)]] = [
        [("mixed", "**Mixed: 2h 30m in Xcode, but 45m of Hades II landed inside the reading block.**\n- Habit app: list editing finished, streak logic started\n- Chapter 6 reading got 70m of the planned 90m\n**Next:** Close the game and give Chapter 6 the last 20m before dinner."),
         ("on_track", "**On track: the reading block recovered and the streak logic compiles.**\n- 40m on Chapter 6 after the 15:00 check-in\n- Social media under 20m all afternoon\n**Next:** Stop at 18:30; tomorrow starts with the physics problem set."),
         ("on_track", "**On track: a light evening that stayed light.**\n- 25m of revision notes, then off the Mac by 21:40\n- No gaming after 19:00\n**Next:** Lay out the physics set first thing tomorrow.")],
        [("on_track", "**On track: 1h 50m on Chapter 5 with two long reading blocks.**\n- Longest focus 64m in Preview\n- 12m of Khan Academy on the hard section, on plan\n**Next:** Start the lab write-up after lunch."),
         ("mixed", "**Mixed: the lab write-up started, then 65m of YouTube took the afternoon.**\n- 60m in VS Code on the analysis script\n- Entertainment video from 15:10 to 16:15\n**Next:** Finish the results section before 18:00; video after.")],
        [("mixed", "**Mixed: 3h 20m of coding, but the problem set for Thursday hasn't started.**\n- Long Xcode blocks, 25m in Discord in between\n- No time yet on the physics set due Thursday\n**Next:** Give the problem set the 15:00–16:30 slot."),
         ("on_track", "**On track: problem set half done in one 85m block.**\n- Questions 1–4 complete\n- Discord held to 10m\n**Next:** Finish questions 5–8 tomorrow morning."),
         ("on_track", "**On track: steady finish to the day.**\n- 35m of research for the essay outline\n- Off the Mac by 22:00\n**Next:** Problem set first, coding after.")],
        [("off_track", "**Off track: 2h 10m of Hades II during the morning study block.**\n- Problem set questions 5–8 still untouched\n- 55m on X and Reddit around it\n**Next:** Close Steam now and do questions 5–6 before 13:00."),
         ("mixed", "**Mixed: questions 5–6 done, the afternoon drifted again.**\n- 40m on the set after the morning check-in\n- 30m more on social media\n**Next:** Questions 7–8 before tonight's tutorial.")],
        [("mixed", "**Mixed: Chapter 7 reading on plan, coding ran long into lunch.**\n- 95m in Preview across two blocks\n- Xcode session went 40m over\n**Next:** Watch the SN1 lecture before 16:00."),
         ("on_track", "**On track: lecture done and notes written.**\n- 40m educational video, 20m of notes\n- Gaming 0m today\n**Next:** Light revision only after 20:00."),
         ("on_track", "**On track: a balanced day overall.**\n- 3h 35m on study and code combined\n- Breaks taken between every long block\n**Next:** Tomorrow: organic chemistry problems first.")],
        [("on_track", "**On track: 1h 30m on the physics lab analysis in VS Code.**\n- Curve fitting working, plots exported\n- 60m of NumPy docs and Stack Overflow, on task\n**Next:** Draft the discussion section after lunch."),
         ("mixed", "**Mixed: discussion drafted, then 30m of video crept in.**\n- 45m of writing\n- Entertainment video 15:20–15:50\n**Next:** Proofread the lab and submit before 18:00.")],
    ]

    /// A synthetic Things Today list: a checklist to-do, a project with its to-dos, and plain items.
    static let thingsItems: [Things.Item] = [
        .init(id: "demo-chem7", title: "Organic Chemistry: read Chapter 7", status: "completed", project: "Chemistry",
              checklist: [.init(title: "7.1 Nucleophilic substitution", done: true), .init(title: "7.2 SN1 vs SN2", done: true),
                          .init(title: "7.3 Elimination reactions", done: true), .init(title: "Margin notes into Notion", done: true)]),
        .init(id: "demo-lab4", title: "Physics lab 4: analysis", notes: "Due Friday. Use the second data run; the first had a loose clamp.",
              due: "2026-10-30", project: "Physics",
              checklist: [.init(title: "Clean the data runs", done: true), .init(title: "Curve fit with numpy.polyfit", done: true),
                          .init(title: "Error bars and residuals", done: false), .init(title: "Discussion section", done: false)]),
        .init(id: "demo-revision", title: "Exam revision week", isProject: true,
              children: [.init(id: "demo-r1", title: "Mon · Kinematics and units", done: true),
                         .init(id: "demo-r2", title: "Tue · Organic mechanisms", done: true),
                         .init(id: "demo-r3", title: "Wed · Problem set 3", done: false),
                         .init(id: "demo-r4", title: "Thu · Past paper, timed", done: false),
                         .init(id: "demo-r5", title: "Fri · Mistakes log review", done: false)]),
        .init(id: "demo-ps3", title: "Problem set 3 (chemistry)", project: "Chemistry",
              checklist: [.init(title: "Questions 1–4", done: false), .init(title: "Questions 5–8", done: false)]),
        .init(id: "demo-habit", title: "Habit app: streak logic", status: "completed", project: "Side projects"),
        .init(id: "demo-review7", title: "Review Chapter 7 before tutorial", project: "Chemistry"),
    ]

    static func seed(into store: AtlasStore, now: Date = Date()) async {
        try? await store.setTodoReason(key: "demo-ps3", title: "Problem set 3 (chemistry)",
                                       reason: "Lab partner needed the analysis first, so I swapped it with the physics lab.")
        let day: [Seg] = [
            Seg(minutes: 48, app: "Preview", bundle: "com.apple.Preview", title: "Organic Chemistry — Chapter 7.pdf", category: .reading),
            Seg(minutes: 17, app: "Google Chrome", bundle: "com.google.Chrome", title: "SN1 vs SN2 explained", domain: "youtube.com", category: .educationalVideo, confidence: 0.7),
            Seg(minutes: 9, app: "Notion", bundle: "notion.id", title: "Chem revision plan", category: .focusedWork, confidence: 0.6),
            Seg(minutes: 6, app: "Messages", bundle: "com.apple.MobileSMS", title: nil, category: .communication),
            Seg(minutes: 14, app: "", bundle: "", title: nil, category: .idle, confidence: 0.85, state: .idle),
            Seg(minutes: 62, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Habit — ContentView.swift", category: .coding),
            Seg(minutes: 11, app: "Google Chrome", bundle: "com.google.Chrome", title: "SwiftUI List selection", domain: "stackoverflow.com", category: .research, confidence: 0.75),
            Seg(minutes: 37, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "Habit — StreakStore.swift", category: .coding),
            Seg(minutes: 8, app: "Google Chrome", bundle: "com.google.Chrome", title: "Home / X", domain: "x.com", category: .socialMedia, confidence: 0.8),
            Seg(minutes: 21, app: "", bundle: "", title: nil, category: .idle, confidence: 0.85, state: .idle),
            Seg(minutes: 16, app: "Hades II", bundle: "com.supergiantgames.hades2.steam", title: nil, category: .gaming),
            Seg(minutes: 41, app: "Code", bundle: "com.microsoft.VSCode", title: "physics-lab — analysis.py", category: .coding),
            Seg(minutes: 7, app: "Google Chrome", bundle: "com.google.Chrome", title: "numpy.polyfit — NumPy Manual", domain: "numpy.org", category: .research, confidence: 0.55),
            Seg(minutes: 3, app: "Discord", bundle: "com.hnc.Discord", title: nil, category: .communication, confidence: 0.6),
            Seg(minutes: 26, app: "Preview", bundle: "com.apple.Preview", title: "Physics Lab 4 — brief.pdf", category: .reading),
        ]
        let total = day.reduce(0) { $0 + $1.minutes }
        var t = now.addingTimeInterval(-total * 60)
        var events: [ActivityEvent] = []
        for s in day {
            let end = t.addingTimeInterval(s.minutes * 60)
            let browser = s.domain.map { BrowserContext(browser: "Chrome", domain: $0, title: s.title) }
            events.append(ActivityEvent(
                start: t, end: end,
                appBundleID: s.bundle.isEmpty ? nil : s.bundle, appName: s.app.isEmpty ? nil : s.app,
                windowTitle: browser == nil ? s.title : nil, browser: browser,
                rawType: s.state == .idle ? .idle : (browser == nil ? .foregroundApp : .browserTab), state: s.state,
                classification: Classification(category: s.category, confidence: s.confidence, evidence: [.appIdentity, .windowTitle])))
            t = end
        }
        try? await store.upsertEvents(events)

        // Six earlier days of plainer history so weekly reports have shape.
        let calendar = Calendar.current
        let pattern: [[(ActivityCategory, String, String, Double)]] = [
            [(.coding, "Xcode", "com.apple.dt.Xcode", 150), (.reading, "Preview", "com.apple.Preview", 70), (.gaming, "Hades II", "com.supergiantgames.hades2.steam", 45), (.socialMedia, "Google Chrome", "com.google.Chrome", 20)],
            [(.reading, "Preview", "com.apple.Preview", 110), (.research, "Google Chrome", "com.google.Chrome", 50), (.entertainmentVideo, "Google Chrome", "com.google.Chrome", 65), (.coding, "Code", "com.microsoft.VSCode", 60)],
            [(.coding, "Xcode", "com.apple.dt.Xcode", 200), (.communication, "Discord", "com.hnc.Discord", 25), (.research, "Google Chrome", "com.google.Chrome", 35)],
            [(.gaming, "Hades II", "com.supergiantgames.hades2.steam", 130), (.socialMedia, "Google Chrome", "com.google.Chrome", 55), (.reading, "Preview", "com.apple.Preview", 40)],
            [(.reading, "Preview", "com.apple.Preview", 95), (.coding, "Xcode", "com.apple.dt.Xcode", 120), (.educationalVideo, "Google Chrome", "com.google.Chrome", 40)],
            [(.coding, "Code", "com.microsoft.VSCode", 90), (.research, "Google Chrome", "com.google.Chrome", 60), (.entertainmentVideo, "Google Chrome", "com.google.Chrome", 30), (.communication, "Messages", "com.apple.MobileSMS", 15)],
        ]
        var history: [ActivityEvent] = []
        for (offset, blocks) in pattern.enumerated() {
            guard let dayStart = calendar.date(byAdding: .day, value: -(offset + 1), to: calendar.startOfDay(for: now)) else { continue }
            var cursor = dayStart.addingTimeInterval(10 * 3600)
            for (cat, app, bundle, minutes) in blocks {
                let end = cursor.addingTimeInterval(minutes * 60)
                history.append(ActivityEvent(start: cursor, end: end, appBundleID: bundle, appName: app, rawType: .foregroundApp,
                                             state: .active, classification: Classification(category: cat, confidence: 0.8, evidence: [.appIdentity])))
                cursor = end.addingTimeInterval(15 * 60)
            }
            for (i, entry) in (pastCheckins[offset]).enumerated() {
                try? await store.saveCheckin(.init(ts: dayStart.addingTimeInterval(Double([10, 15, 21][min(i, 2)]) * 3600), source: "demo",
                                                   verdict: entry.0, body: entry.1))
            }
        }
        try? await store.upsertEvents(history)

        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        func at(_ h: Int) -> Date { cal.date(byAdding: .hour, value: h, to: start) ?? now }
        let latest = min(now.addingTimeInterval(-20 * 60), max(at(12), now.addingTimeInterval(-150 * 60)))
        try? await store.saveCheckin(.init(ts: latest.addingTimeInterval(-3 * 3600), source: "demo", verdict: "mixed", body: """
            **Mixed: chemistry reading got 48m, but the problem set hasn't started.**
            - 48m on Chapter 7 and a 17m SN1/SN2 explainer, both on plan
            - Revision plan open for 9m, then a 14m break
            **Next:** Start problem set 3 before the 14:00 lab session.
            """))
        try? await store.saveCheckin(.init(ts: latest, source: "demo", verdict: "on_track", body: """
            **On track: 1h 39m of focused coding on the Habit app, gaming held to 16m.**
            - Longest focus block 62m in Xcode, with 11m of Stack Overflow research in between
            - X and Discord together under 12m
            **Next:** Finish the physics lab analysis, then review Chapter 7 before the 16:30 tutorial.
            """, todos: [
                .init(title: "Organic Chemistry: read Chapter 7", status: "done", minutes: 48),
                .init(title: "Habit app: streak logic", status: "done", minutes: 99),
                .init(title: "Physics lab 4: analysis", status: "in_progress", minutes: 41, note: "Curve fit working; discussion left"),
                .init(title: "Problem set 3 (chemistry)", status: "not_started"),
                .init(title: "Review Chapter 7 before tutorial", status: "not_started"),
                .init(title: "Reply to lab partner", status: "done", minutes: 6),
            ]))
    }
}
