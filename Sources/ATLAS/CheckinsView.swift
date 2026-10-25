import AtlasCore
import SwiftUI

/// Check-ins: the day's verdicts on a rail, newest first. Analyses (in-app windows) sit behind a tab.
struct CheckinsView: View {
    @Environment(AppModel.self) private var model
    enum Tab: String, CaseIterable { case checkins = "Check-ins", analyses = "Analyses" }
    @State private var tab: Tab = .checkins

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Check-ins", subtitle: subtitle) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 38)
            .padding(.bottom, 20)

            switch tab {
            case .checkins: rail
            case .analyses: AgentView()
            }
        }
        .task { await model.refresh() }
    }

    private var subtitle: String {
        let plan = model.settings.checkinPlan
        if let p = plan.pausedUntil, p > Date() { return "Paused until \(Fmt.dayTime.string(from: p))" }
        if let next = model.nextCheckin {
            let day = Calendar.current.isDateInToday(next) ? "" : (Calendar.current.isDateInTomorrow(next) ? "tomorrow " : Fmt.longDay.string(from: next) + " ")
            return "Next check-in \(day)at \(Fmt.time.string(from: next)) · change in Settings → Check-ins"
        }
        return "No check-ins scheduled · choose times in Settings → Check-ins"
    }

    private var rail: some View {
        ScrollView {
            if model.checkins.isEmpty {
                Panel(padding: 28) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No check-ins yet").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("Check-ins come from the ATLAS Check-in task in the Claude app, at the times you choose in Settings → Check-ins. Each one reads this tracker, compares it with your plan, and saves its verdict here.")
                            .font(.system(size: 13.5)).foregroundStyle(Theme.inkSecondary).frame(maxWidth: 620, alignment: .leading)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let groups = Dictionary(grouping: model.checkins) { Calendar.current.startOfDay(for: $0.ts) }
                    ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                        Text(Calendar.current.isDateInToday(day) ? "Today" : Fmt.longDay.string(from: day))
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.inkSecondary)
                            .padding(.leading, 40).padding(.top, 8).padding(.bottom, 14)
                        let items = groups[day]!.sorted { $0.ts > $1.ts }
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                            CheckinRow(checkin: c, isLast: i == items.count - 1)
                        }
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .scrollIndicators(.never)
    }
}

private struct CheckinRow: View {
    var checkin: AtlasStore.Checkin
    var isLast: Bool

    var body: some View {
        let v = Verdict(checkin.verdict)
        let parts = CheckinParts(checkin.body)
        HStack(alignment: .top, spacing: 18) {
            // Rail: verdict node and the line to the previous check-in.
            VStack(spacing: 0) {
                Image(systemName: v.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(v.color)
                    .frame(width: 22, height: 22)
                    .background(Theme.window, in: Circle())
                if !isLast { Rectangle().fill(Theme.hairline).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(v.title).font(.system(size: 17, weight: .bold)).foregroundStyle(v.color)
                        Text(Fmt.time.string(from: checkin.ts)).font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.inkTertiary)
                        Spacer()
                    }
                    if !parts.headline.isEmpty {
                        Text(parts.headline).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    ForEach(parts.evidence, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.inkTertiary).frame(width: 4, height: 4).offset(y: -3)
                            Text(line).font(.system(size: 13.5)).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }
                    if let next = parts.next {
                        ForEach(Array(next.components(separatedBy: "\n").enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "arrow.forward").font(.system(size: 11, weight: .bold)).foregroundStyle(v.color)
                                Text(step).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.bottom, 26)
                if !isLast { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.bottom, 22) }
            }
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}
