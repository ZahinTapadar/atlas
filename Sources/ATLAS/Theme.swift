import AppKit
import AtlasCore
import SwiftUI

/// ATLAS design tokens. Graphite neutrals tinted from the icon, ink as the brand colour,
/// verdict colours as the only saturated fields, category colours reserved for data.
enum Theme {
    // Grounds
    static let window = Color.dyn(0xF4F4F6, 0x0E0E10)
    static let sidebar = Color.dyn(0xEAEAEE, 0x17171A)
    static let surface = Color.dyn(0xFFFFFF, 0x1A1A1E)
    static let surfaceRaised = Color.dyn(0xF6F6F8, 0x222227)
    static let selection = Color.dyn(0xFFFFFF, 0x2A2A30)
    static let hairline = Color.dyn(0x000000, 0xFFFFFF, alpha: 0.08)
    static let track = Color.dyn(0x000000, 0xFFFFFF, alpha: 0.06)

    // Ink
    static let ink = Color.dyn(0x111113, 0xF4F4F6)
    static let inkSecondary = Color.dyn(0x55555D, 0xA1A1AA)
    static let inkTertiary = Color.dyn(0x6A6A72, 0x8F8F99)

    // Verdicts: the only saturated fields in the shell.
    static let onTrack = Color.dyn(0x16804A, 0x3DD68C)
    static let mixed = Color.dyn(0xA86400, 0xF5B342)
    static let offTrack = Color.dyn(0xC62828, 0xFF6B6B)
    static let neutral = Color.dyn(0x5E5E66, 0xA1A1AA)

    static let live = Color.dyn(0x16A34A, 0x3DD68C)

    // Geometry
    static let radiusPanel: CGFloat = 20
    static let radiusRow: CGFloat = 10
    static let gutter: CGFloat = 32
}

extension Color {
    /// A colour that adapts to light and dark appearance.
    static func dyn(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        })
    }
}

/// Check-in verdict vocabulary shared by the Today panel, Check-ins and the menu bar.
enum Verdict: String {
    case onTrack = "on_track", mixed, offTrack = "off_track", insufficient = "insufficient_data", none

    init(_ raw: String?) { self = Verdict(rawValue: raw ?? "") ?? .none }

    var title: String {
        switch self {
        case .onTrack: "On track"
        case .mixed: "Mixed"
        case .offTrack: "Off track"
        case .insufficient: "Not enough data"
        case .none: "No check-in yet"
        }
    }

    var color: Color {
        switch self {
        case .onTrack: Theme.onTrack
        case .mixed: Theme.mixed
        case .offTrack: Theme.offTrack
        case .insufficient, .none: Theme.neutral
        }
    }

    var symbol: String {
        switch self {
        case .onTrack: "checkmark.circle.fill"
        case .mixed: "circle.lefthalf.filled"
        case .offTrack: "exclamationmark.circle.fill"
        case .insufficient, .none: "circle.dashed"
        }
    }
}

// MARK: - Shared surfaces

/// The one panel shape: continuous corners, quiet fill, no stroke in light mode.
struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusPanel, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// An unboxed section: a hairline rule above, content set on the window ground.
/// Typographic hierarchy does the grouping; only the verdict gets a filled field.
struct OpenSection<Content: View>: View {
    var spacing: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            content.padding(.top, spacing)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Section heading: the heading carries its own weight, no label above it.
struct SectionHeading: View {
    var title: String
    var detail: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.inkTertiary).monospacedDigit() }
        }
    }
}

/// Page title used at the top of every main screen.
struct PageHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.inkSecondary) }
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

/// Capsule button style used for primary page actions.
struct InkButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.window : Theme.ink)
            .background(prominent ? Theme.ink : Theme.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? .clear : Theme.hairline))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
