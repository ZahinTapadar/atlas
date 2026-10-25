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
    static func range(_ a: Date, _ b: Date?) -> String { "\(time.string(from: a))–\(b.map { time.string(from: $0) } ?? "now")" }
}

extension ActivityCategory {
    var color: Color {
        switch self {
        case .focusedWork: .indigo
        case .coding: .blue
        case .research: .teal
        case .reading: .cyan
        case .educationalVideo: .mint
        case .entertainmentVideo: .pink
        case .socialMedia: .orange
        case .gaming: .purple
        case .communication: .yellow
        case .administrative: .brown
        case .personalOrganization: .green
        case .breakTime: Color(nsColor: .systemGray)
        case .idle: Color(nsColor: .quaternaryLabelColor)
        // Distinct from idle grey: "we saw activity but couldn't tell what it was".
        case .unknown: Color(red: 0.85, green: 0.65, blue: 0.2)
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
        Circle().fill(level == .ok ? Color.green : level == .degraded ? Color.orange : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
    }
}

struct ConfidenceBadge: View {
    var classification: Classification
    var body: some View {
        let c = classification
        Group {
            if c.origin == .userConfirmed {
                Label("Confirmed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else if c.isUncertain {
                Label("Uncertain \(Int(c.confidence * 100))%", systemImage: "questionmark.diamond").foregroundStyle(.orange)
            } else {
                Text("\(Int(c.confidence * 100))%").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .help(c.explanation ?? "")
    }
}

struct Card<Content: View>: View {
    var title: String
    var systemImage: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                Text(title).font(.headline)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5)))
    }
}

struct Metric: View {
    var label: String
    var value: String
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// Horizontal day strip: one colored band per event, idle and gaps shown faintly.
struct DayStrip: View {
    var events: [ActivityEvent]
    var start: Date
    var end: Date
    var body: some View {
        GeometryReader { geo in
            let span = max(1, end.timeIntervalSince(start))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                ForEach(events) { e in
                    let x = max(0, e.start.timeIntervalSince(start)) / span * geo.size.width
                    let w = max(1, e.duration / span * geo.size.width)
                    Rectangle()
                        .fill(e.privacy == .excluded ? Color.gray.opacity(0.4) : e.classification.category.color
                            .opacity(e.state.isEngaged ? (e.classification.isUncertain ? 0.45 : 1) : 0.25))
                        .frame(width: w)
                        .offset(x: x)
                        .help("\(e.displayLabel)\n\(Fmt.range(e.start, e.end)) · \(e.classification.category.displayName)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 22)
    }
}

struct CategoryLegendRow: View {
    var category: ActivityCategory
    var observed: TimeInterval
    var inferred: TimeInterval
    var total: TimeInterval
    var body: some View {
        HStack {
            Image(systemName: category.icon).foregroundStyle(category.color).frame(width: 18)
            Text(category.displayName)
            Spacer()
            if inferred > 60 {
                Text("incl. \(Fmt.duration(inferred)) inferred").font(.caption2).foregroundStyle(.secondary)
            }
            Text(Fmt.duration(observed)).monospacedDigit()
            ProgressView(value: total > 0 ? observed / total : 0).frame(width: 70).tint(category.color)
        }
        .font(.callout)
    }
}
