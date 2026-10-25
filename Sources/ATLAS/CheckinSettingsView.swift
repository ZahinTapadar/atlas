import AtlasCore
import SwiftUI

/// Settings → Check-ins: when the scheduled check-in happens, pausing and skipping, and a real check-in now.
/// The Claude task wakes every hour from 6 to 23 and asks ATLAS (`should_check_in`) whether to go ahead.
struct CheckinSettings: View {
    @Environment(AppModel.self) private var model
    @State private var gated = true

    private static let dayLetters = [(2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S")]
    private static let dayNames = [1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday", 5: "Thursday", 6: "Friday", 7: "Saturday"]

    var body: some View {
        let plan = model.settings.checkinPlan
        Form {
            Section {
                LabeledContent("Days") {
                    HStack(spacing: 6) {
                        ForEach(Self.dayLetters, id: \.0) { day, letter in
                            Toggle(letter, isOn: Binding(
                                get: { plan.weekdays.contains(day) },
                                set: { on in model.updatePlan { p in
                                    if on { p.weekdays = Array(Set(p.weekdays + [day])).sorted() } else { p.weekdays.removeAll { $0 == day } }
                                } }))
                            .toggleStyle(.button).help(Self.dayNames[day] ?? "")
                        }
                    }
                }
                LabeledContent("Times") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 6), count: 6), alignment: .trailing, spacing: 6) {
                        ForEach(CheckinPlan.runHours, id: \.self) { h in
                            Toggle(isOn: Binding(
                                get: { plan.hours.contains(h) },
                                set: { on in model.updatePlan { p in
                                    if on { p.hours = Array(Set(p.hours + [h])).sorted() } else { p.hours.removeAll { $0 == h } }
                                } })) {
                                Text(hourLabel(h)).monospacedDigit().frame(width: 50)
                            }
                            .toggleStyle(.button)
                        }
                    }
                }
                LabeledContent("Next check-in", value: nextText(plan))
            } header: {
                Text("When")
            } footer: {
                Text("Pick any hours from 6 AM to 11 PM. Fewer check-ins means fewer emails; three to five a day works well.")
            }

            Section("Pause and skip") {
                if let until = plan.pausedUntil, until > Date() {
                    LabeledContent("Paused until \(Fmt.dayTime.string(from: until))") {
                        Button("Resume") { model.updatePlan { $0.pausedUntil = nil } }
                    }
                } else {
                    LabeledContent("Pause check-ins") {
                        Menu("Pause…") {
                            Button("For the rest of today") { pause(until: endOfToday()) }
                            Button("Until tomorrow evening") { pause(until: tomorrow(at: 18)) }
                            Button("For 3 days") { pause(until: days(3)) }
                            Button("For a week") { pause(until: days(7)) }
                        }
                        .fixedSize()
                    }
                }
                if let skipped = plan.skippedSlot, skipped > Date() {
                    LabeledContent("Skipping the \(Fmt.time.string(from: skipped)) check-in") {
                        Button("Undo") { model.updatePlan { $0.skippedSlot = nil } }
                    }
                } else if let next = model.nextCheckin {
                    LabeledContent("Skip just the next one") {
                        Button("Skip \(Fmt.time.string(from: next))") { model.updatePlan { $0.skippedSlot = next } }
                    }
                }
            }

            Section {
                LabeledContent("Check in now") {
                    HStack {
                        if model.checkinRunning { ProgressView().controlSize(.small) }
                        Button(model.checkinRunning ? "Checking in…" : "Run a check-in") { Task { await model.runCheckinNow() } }
                            .disabled(model.checkinRunning || model.claudeCodePath == nil)
                    }
                }
                if let msg = model.checkinRunMessage { Text(msg).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Runs the full check-in right away: verdict, Things, calendar and email. A scheduled one within the next 45 minutes is then skipped so you don't get two.")
            }

            Section("How it works") {
                if !model.checkinTaskInstalled {
                    Text("There's no check-in task in Claude yet. Open Settings → General → Permissions & setup… and follow “Check-in schedule”.")
                        .font(.callout)
                } else if gated {
                    Text("Your Claude check-in task wakes every hour from 6 AM to 11 PM and asks ATLAS first. Hours you haven't chosen, pauses and skips stop there, after one quick question.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your Claude check-in task still runs at fixed times, so these settings don't apply yet. Copy the update, paste it into a chat in the Claude app and send it.")
                            .font(.callout)
                        Button("Copy update request and open Claude") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(CheckinTask.upgradeRequest, forType: .string)
                            model.openClaude()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            gated = CheckinTask.installedPrompt()?.contains("should_check_in") ?? true
            model.checkinTaskInstalled = CheckinTask.isInstalled()
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("j")
        return f.string(from: Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date())
    }

    private func nextText(_ plan: CheckinPlan) -> String {
        guard let n = plan.next() else { return plan.hours.isEmpty || plan.weekdays.isEmpty ? "None: pick at least one day and time" : "None in the next two weeks" }
        let cal = Calendar.current
        let day = cal.isDateInToday(n) ? "Today" : cal.isDateInTomorrow(n) ? "Tomorrow" : Fmt.longDay.string(from: n)
        return "\(day), \(Fmt.time.string(from: n))"
    }

    private func pause(until: Date) { model.updatePlan { $0.pausedUntil = until; $0.skippedSlot = nil } }
    private func endOfToday() -> Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))! }
    private func tomorrow(at h: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: endOfToday())! }
    private func days(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: Date())! }
}
