import AtlasCore
import SwiftUI

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static let dayTime: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .short; return f }()
    static let longDay: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEdMMMM"); return f }()
    static let hour: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("j"); return f }()
    static func range(_ a: Date, _ b: Date?) -> String { "\(time.string(from: a))–\(b.map { time.string(from: $0) } ?? "now")" }
}

extension ActivityCategory {
    /// Data colours only: never used for chrome.
    var color: Color {
        switch self {
        case .focusedWork: .dyn(0x5B5BD6, 0x8B8BF5)
        case .coding: .dyn(0x2F6BFF, 0x5C8DFF)
        case .research: .dyn(0x0F9F98, 0x2DD4C4)
        case .reading: .dyn(0x0B8BC6, 0x38BDF8)
        case .educationalVideo: .dyn(0x5E9E10, 0x9BD94A)
        case .entertainmentVideo: .dyn(0xD9387E, 0xF472B6)
        case .socialMedia: .dyn(0xE2600F, 0xFB923C)
        case .gaming: .dyn(0x7C4DDB, 0xA78BFA)
        case .communication: .dyn(0xB8860B, 0xF2C94C)
        case .administrative: .dyn(0x8A847C, 0xA8A29E)
        case .personalOrganization: .dyn(0x0E9F6E, 0x34D399)
        case .breakTime: .dyn(0x94A3B8, 0x64748B)
        case .idle: .dyn(0xD7D7DD, 0x2E2E34)
        case .unknown: .dyn(0xB59248, 0xC9A55A)
        }
    }
    var icon: String {
        switch self {
        case .focusedWork: "target"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .research: "magnifyingglass"
        case .reading: "book"
        case .educationalVideo: "graduationcap"
        case .entertainmentVideo: "play.tv"
        case .socialMedia: "bubble.left.and.bubble.right"
        case .gaming: "gamecontroller"
        case .communication: "envelope"
        case .administrative: "gearshape"
        case .personalOrganization: "calendar"
        case .breakTime: "cup.and.saucer"
        case .idle: "moon.zzz"
        case .unknown: "questionmark.circle"
        }
    }
}

struct StatusDot: View {
    var level: HealthItem.Level
    var body: some View {
        Circle().fill(level == .ok ? Theme.live : level == .degraded ? Theme.mixed : Theme.inkTertiary.opacity(0.5))
            .frame(width: 7, height: 7)
    }
}

struct ConfidenceBadge: View {
    var classification: Classification
    var body: some View {
        let c = classification
        Group {
            if c.origin == .userConfirmed {
                Label("Confirmed", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.onTrack)
            } else if c.isUncertain {
                Label("\(Int(c.confidence * 100))%", systemImage: "questionmark.diamond").foregroundStyle(Theme.mixed)
            } else {
                Text("\(Int(c.confidence * 100))%").foregroundStyle(Theme.inkTertiary)
            }
        }
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        .labelStyle(.titleAndIcon)
        .help(c.explanation ?? "")
    }
}

/// Category chip: colour dot plus name, used in tables and lists.
struct CategoryChip: View {
    var category: ActivityCategory
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(category.color).frame(width: 7, height: 7)
            Text(category.displayName).foregroundStyle(Theme.ink)
        }
        .font(.system(size: 12.5))
    }
}

/// Generic titled panel (Reports, Settings-adjacent views).
struct Card<Content: View>: View {
    var title: String
    var systemImage: String?
    @ViewBuilder var content: Content
    var body: some View {
        OpenSection {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeading(title: title)
                content
            }
        }
    }
}

/// A typeset figure: value first, label beside it, no tile.
struct Metric: View {
    var label: String
    var value: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).tracking(-0.3).foregroundStyle(Theme.ink)
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.inkSecondary)
            if let caption { Text(caption).font(.system(size: 11)).foregroundStyle(Theme.inkTertiary) }
        }
    }
}

/// Compact strip used outside Today (reports, menu): one band per event.
struct DayStrip: View {
    var events: [ActivityEvent]
    var start: Date
    var end: Date
    var body: some View {
        GeometryReader { geo in
            let span = max(1, end.timeIntervalSince(start))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                ForEach(events) { e in
                    Rectangle()
                        .fill(e.privacy == .excluded ? Theme.inkTertiary.opacity(0.4) : e.classification.category.color
                            .opacity(e.state.isEngaged ? (e.classification.isUncertain ? 0.45 : 1) : 0.2))
                        .frame(width: max(1, e.duration / span * geo.size.width))
                        .offset(x: max(0, e.start.timeIntervalSince(start)) / span * geo.size.width)
                        .help("\(e.displayLabel)\n\(Fmt.range(e.start, e.end)) · \(e.classification.category.displayName)")
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 10)
    }
}

struct CategoryLegendRow: View {
    var category: ActivityCategory
    var observed: TimeInterval
    var inferred: TimeInterval
    var total: TimeInterval
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: category.icon).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(category.color).frame(width: 18)
                Text(category.displayName).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if inferred > 60 {
                    Text("\(Fmt.duration(inferred)) inferred").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary)
                }
                Spacer()
                Text(Fmt.duration(observed)).font(.system(size: 13, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(category.color).frame(width: max(4, g.size.width * (total > 0 ? observed / total : 0)))
                }
            }
            .frame(height: 4)
            .padding(.leading, 28)
        }
    }
}

extension AllocationGroup {
    var color: Color {
        switch self {
        case .activeWork: ActivityCategory.coding.color
        case .learning: ActivityCategory.research.color
        case .reading: ActivityCategory.reading.color
        case .entertainment: ActivityCategory.entertainmentVideo.color
        case .gaming: ActivityCategory.gaming.color
        case .socialMedia: ActivityCategory.socialMedia.color
        case .communication: ActivityCategory.communication.color
        case .breaks: ActivityCategory.breakTime.color
        case .idleOrUncertain: .dyn(0xC4C4CC, 0x4A4A52)
        }
    }
}
