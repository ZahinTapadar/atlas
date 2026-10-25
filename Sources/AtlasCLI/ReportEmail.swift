import AtlasCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Reports tab, as email: a scorecard, today's figures against yesterday, productive vs distracting time,
/// then the week (day by day, when you focus, check-in record, top apps and sites). Charts are animated GIFs.
enum ReportEmail {
    typealias Inline = (cid: String, data: Data)

    static let on = "#3dd68c", mixed = "#f5b342", off = "#ff6b6b"
    static var ink: String { RichEmail.ink }
    static var ink2: String { RichEmail.ink2 }
    static var ink3: String { RichEmail.ink3 }
    static var card: String { RichEmail.card }
    static var line: String { RichEmail.line }

    static func groupHex(_ g: AllocationGroup) -> UInt32 {
        switch g {
        case .activeWork: 0x5C8DFF
        case .learning: 0x2DD4C4
        case .reading: 0x38BDF8
        case .entertainment: 0xF472B6
        case .gaming: 0xA78BFA
        case .socialMedia: 0xFB923C
        case .communication: 0xF2C94C
        case .breaks: 0x64748B
        case .idleOrUncertain: 0x4A4A52
        }
    }

    // MARK: Sections

    /// `top` goes right under the verdict (the scorecard); `bottom` follows the to-dos.
    static func sections(today: Report, week: Report, checkins: [AtlasStore.Checkin], now: Date = Date()) -> (top: String, bottom: String, images: [Inline]) {
        var h = ""
        var images: [Inline] = []
        let all = Set(AllocationGroup.charted)
        let prod = today.total(AllocationGroup.productive), dist = today.total(AllocationGroup.distractions)
        let engagedToday = today.total(all)

        // Scorecard
        let streak = focusStreak(week)
        let onTrack = onTrackStreak(checkins, now: now)
        let best = week.buckets.max { $0.byGroup.filter { AllocationGroup.productive.contains($0.key) }.values.reduce(0, +)
            < $1.byGroup.filter { AllocationGroup.productive.contains($0.key) }.values.reduce(0, +) }
        let bestTime = best.map { $0.byGroup.filter { AllocationGroup.productive.contains($0.key) }.values.reduce(0, +) } ?? 0
        let share = engagedToday > 0 ? Int((prod / engagedToday * 100).rounded()) : 0
        let peak = peakCell(week)
        h += heading("Scorecard", detail: nil)
        h += grid([
            tile(value: "\(share)%", label: "of today on work, learning and reading", accent: share >= 60 ? on : (share >= 40 ? mixed : off), bar: Double(share) / 100),
            tile(value: "\(streak) day\(streak == 1 ? "" : "s")", label: "focus streak · days with most time on work, learning and reading", accent: streak >= 3 ? on : ink, bar: nil),
            tile(value: "\(onTrack)", label: "on-track check-ins in a row", accent: onTrack >= 2 ? on : ink, bar: nil),
            tile(value: best.map { weekday($0.start) } ?? "–", label: best == nil ? "best day this week" : "best day this week · \(Fmt.duration(bestTime)) productive", accent: ink, bar: nil),
        ])
        if let peak {
            h += "<tr><td style=\"padding:2px 6px 0;font-size:13px;color:\(ink2);\">Peak focus: <b style=\"color:\(ink);\">\(peak)</b></td></tr>"
        }
        let top = h
        h = ""

        // Today against yesterday
        h += heading("Today", detail: "against yesterday")
        h += grid(figureTiles(today))
        if prod + dist > 0 {
            let pPct = Int((prod / max(prod + dist, 1) * 100).rounded())
            h += "<tr><td style=\"padding:12px 0 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:\(card);border-radius:18px;\"><tr><td style=\"padding:16px 18px;\">"
            h += "<table role=\"presentation\" width=\"100%\"><tr><td style=\"font-size:13px;color:\(ink2);\">Productive<br><span style=\"font-size:24px;font-weight:800;color:\(on);\">\(Fmt.duration(prod))</span></td>"
            h += "<td align=\"right\" style=\"font-size:13px;color:\(ink2);\">Distractions<br><span style=\"font-size:24px;font-weight:800;color:\(off);\">\(Fmt.duration(dist))</span></td></tr></table>"
            h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top:10px;\"><tr>"
            h += "<td width=\"\(max(pPct, 3))%\" style=\"height:10px;background:\(on);border-radius:5px 0 0 5px;font-size:0;\">&nbsp;</td>"
            h += "<td style=\"height:10px;background:\(off);border-radius:0 5px 5px 0;font-size:0;\">&nbsp;</td></tr></table>"
            h += "<div style=\"font-size:12.5px;color:\(ink3);margin-top:8px;\">Productive: work, learning and reading. Distractions: video, games and social media.</div>"
            h += "</td></tr></table></td></tr>"
        }

        // The week
        let wAll = week.total(all), wPrev = week.total(all, previous: true)
        let wShare = wAll > 0 ? week.total(AllocationGroup.productive) / wAll : 0
        let wPrevShare = wPrev > 0 ? week.total(AllocationGroup.productive, previous: true) / wPrev : 0
        let delta = Int(((wShare - wPrevShare) * 100).rounded())
        h += heading("This week", detail: week.rangeLabel)
        h += "<tr><td style=\"padding:0 6px 12px;font-size:20px;line-height:1.35;font-weight:700;color:\(ink2);\"><span style=\"color:\(ink);\">\(Fmt.duration(wAll))</span> engaged, <span style=\"color:\(ink);\">\(Int((wShare * 100).rounded()))%</span> of it on work, learning and reading."
        if wPrev >= 60 && delta != 0 {
            h += " <span style=\"font-size:14px;font-weight:700;color:\(delta > 0 ? on : off);\">\(delta > 0 ? "▲" : "▼") \(abs(delta)) points vs the week before</span>"
        }
        h += "</td></tr>"
        let activeDays = week.buckets.filter { $0.byGroup.values.reduce(0, +) >= 10 * 60 }.count
        if activeDays >= 2 {
            h += grid(figureTiles(week))
            h += balance(week)
        } else {
            h += "<tr><td style=\"padding:0 6px 4px;font-size:13px;color:\(ink3);\">ATLAS has \(activeDays == 1 ? "one day" : "no full day") of history so far; the week fills in as you go.</td></tr>"
        }

        if let bars = barsGIF(week) {
            images.append(("week@atlas", bars))
            h += heading("Day by day", detail: nil)
            h += imageCard(cid: "week@atlas", alt: "Hours per day this week, stacked by activity", legend: legend(week))
        }
        if let heat = heatGIF(week) {
            images.append(("focus@atlas", heat))
            h += heading("When you focus", detail: peak.map { "Peak: \($0)" })
            h += imageCard(cid: "focus@atlas", alt: "Work, learning and reading by weekday and hour", legend: nil)
        }
        h += checkinRecord(week.days, checkins: checkins)
        h += topSources(week)
        return (top, h, images)
    }

    // MARK: Pieces

    private static func heading(_ t: String, detail: String?) -> String {
        "<tr><td style=\"padding:28px 6px 10px;\"><table role=\"presentation\" width=\"100%\"><tr><td style=\"font-size:16px;font-weight:700;color:\(ink);\">\(RichEmail.esc(t))</td>"
            + "<td align=\"right\" style=\"font-size:12.5px;color:\(ink3);\">\(RichEmail.esc(detail ?? ""))</td></tr></table></td></tr>"
    }

    /// Two tiles per row.
    private static func grid(_ tiles: [String]) -> String {
        var h = "<tr><td><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"table-layout:fixed;\">"
        for row in stride(from: 0, to: tiles.count, by: 2) {
            h += "<tr><td width=\"50%\" valign=\"top\" style=\"padding:0 5px 10px 0;\">\(tiles[row])</td>"
            h += "<td width=\"50%\" valign=\"top\" style=\"padding:0 0 10px 5px;\">\(row + 1 < tiles.count ? tiles[row + 1] : "")</td></tr>"
        }
        return h + "</table></td></tr>"
    }

    private static func tile(value: String, label: String, accent: String, bar: Double?, delta: String? = nil) -> String {
        var h = "<div style=\"background:\(card);border-radius:16px;padding:14px 14px 13px;min-height:84px;\">"
        h += "<div style=\"font-size:26px;line-height:1.1;font-weight:800;letter-spacing:-0.5px;color:\(accent);\">\(RichEmail.esc(value))</div>"
        if let delta { h += delta }
        h += "<div style=\"font-size:12.5px;line-height:1.35;color:\(ink2);margin-top:6px;\">\(RichEmail.esc(label))</div>"
        if let bar {
            h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top:9px;\"><tr>"
            h += "<td width=\"\(max(3, Int(bar * 100)))%\" style=\"height:5px;background:\(accent);border-radius:3px;font-size:0;\">&nbsp;</td>"
            h += "<td style=\"height:5px;background:#2a2a30;border-radius:3px;font-size:0;\">&nbsp;</td></tr></table>"
        }
        return h + "</div>"
    }

    private static func figureTiles(_ r: Report) -> [String] {
        let f = r.figures, p = r.previous
        let hours = f.engaged / 3600, prevHours = p.engaged / 3600
        func chip(_ now: Double, _ before: Double, better: Bool) -> String? {
            guard before > 0.0001, p.engaged >= 60 else { return nil }
            let d = (now - before) / before
            guard abs(d) >= 0.01 else { return nil }
            let up = d > 0, tone = up == better ? on : off
            return "<div style=\"display:inline-block;margin-top:6px;padding:2px 8px;border-radius:9px;background:\(tone)22;color:\(tone);font-size:12px;font-weight:700;\">\(up ? "▲" : "▼") \(Int((abs(d) * 100).rounded()))%</div>"
        }
        let sph = hours > 0 ? Double(f.switches) / hours : 0, psph = prevHours > 0 ? Double(p.switches) / prevHours : 0
        return [
            tile(value: Fmt.duration(r.total(Set(AllocationGroup.charted))), label: r.uncertain >= 60 ? "engaged · \(Fmt.duration(r.uncertain)) uncertain not counted" : "engaged",
                 accent: ink, bar: nil, delta: chip(r.total(Set(AllocationGroup.charted)), r.total(Set(AllocationGroup.charted), previous: true), better: true)),
            tile(value: Fmt.duration(f.longestFocus), label: "longest focus", accent: ink, bar: nil, delta: chip(f.longestFocus, p.longestFocus, better: true)),
            tile(value: "\(f.sessions)", label: "focus sessions of 25 min or more", accent: ink, bar: nil, delta: chip(Double(f.sessions), Double(p.sessions), better: true)),
            tile(value: hours > 0 ? String(format: "%.0f", sph) : "–", label: "app switches per hour", accent: ink, bar: nil, delta: hours > 0 && prevHours > 0 ? chip(sph, psph, better: false) : nil),
        ]
    }

    /// One proportional bar of where the time went, with a legend.
    private static func balance(_ r: Report) -> String {
        let groups = AllocationGroup.charted.filter { (r.groupTotals[$0] ?? 0) >= 60 }
        let sum = groups.reduce(0) { $0 + (r.groupTotals[$1] ?? 0) }
        guard sum > 0 else { return "" }
        var h = "<tr><td style=\"padding:2px 0 0;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:\(card);border-radius:18px;\"><tr><td style=\"padding:16px 18px;\">"
        h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr>"
        for g in groups {
            let pct = max(1, Int(((r.groupTotals[g] ?? 0) / sum * 100).rounded()))
            h += "<td width=\"\(pct)%\" style=\"height:14px;background:\(muted(groupHex(g)));border-left:2px solid \(card);font-size:0;\">&nbsp;</td>"
        }
        h += "</tr></table><div style=\"margin-top:8px;\">"
        for g in groups {
            h += "<span style=\"display:inline-block;margin:6px 14px 0 0;font-size:12.5px;color:\(ink2);\"><span style=\"display:inline-block;width:8px;height:8px;border-radius:4px;background:\(RichEmail.hex(groupHex(g)));margin-right:6px;\"></span>\(RichEmail.esc(g.displayName)) <span style=\"color:\(ink3);\">\(Fmt.duration(r.groupTotals[g] ?? 0))</span></span>"
        }
        return h + "</div></td></tr></table></td></tr>"
    }

    private static func legend(_ r: Report) -> String {
        AllocationGroup.charted.filter { (r.groupTotals[$0] ?? 0) >= 60 }.map { g in
            "<span style=\"display:inline-block;margin:8px 14px 0 0;font-size:12px;color:\(ink2);\"><span style=\"display:inline-block;width:8px;height:8px;border-radius:4px;background:\(RichEmail.hex(groupHex(g)));margin-right:6px;\"></span>\(RichEmail.esc(g.shortName))</span>"
        }.joined()
    }

    private static func imageCard(cid: String, alt: String, legend: String?) -> String {
        "<tr><td style=\"background:\(card);border-radius:18px;padding:16px 16px 12px;\"><img src=\"cid:\(cid)\" width=\"100%\" alt=\"\(RichEmail.esc(alt))\" style=\"display:block;width:100%;max-width:536px;height:auto;border:0;\">"
            + (legend.map { "<div>\($0)</div>" } ?? "") + "</td></tr>"
    }

    private static func checkinRecord(_ days: [Date], checkins: [AtlasStore.Checkin]) -> String {
        let cal = Calendar.current
        let inRange = checkins.filter { c in days.contains { cal.isDate($0, inSameDayAs: c.ts) } }
        guard !inRange.isEmpty else { return "" }
        let counts = Dictionary(grouping: inRange, by: { $0.verdict ?? "" }).mapValues(\.count)
        let judged = (counts["on_track"] ?? 0) + (counts["mixed"] ?? 0) + (counts["off_track"] ?? 0)
        var h = heading("Check-in record", detail: "\(counts["on_track"] ?? 0) of \(judged) on track")
        h += "<tr><td style=\"background:\(card);border-radius:18px;padding:16px 14px;\">"
        // Verdict proportions
        h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\"><tr>"
        for (k, c) in [("on_track", on), ("mixed", mixed), ("off_track", off)] {
            if let n = counts[k], n > 0 { h += "<td width=\"\(max(4, n * 100 / max(judged, 1)))%\" style=\"height:8px;background:\(c);border-left:2px solid \(card);font-size:0;\">&nbsp;</td>" }
        }
        h += "</tr></table>"
        // Grid: one column per day, one row per scheduled hour.
        h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"4\" style=\"margin-top:10px;table-layout:fixed;\"><tr><td width=\"26\"></td>"
        for d in days { h += "<td align=\"center\" style=\"font-size:11px;color:\(ink3);\">\(String(weekday(d).prefix(2)))</td>" }
        h += "</tr>"
        for hour in [9, 12, 15, 18, 21] {
            h += "<tr><td style=\"font-size:11px;color:\(ink3);\">\(hour)</td>"
            for d in days {
                let c = inRange.first { cal.isDate($0.ts, inSameDayAs: d) && nearestSlot($0.ts) == hour }
                let color = c.map { RichEmail.verdictColor($0.verdict) } ?? "#26262b"
                let mark = c.map { $0.verdict == "on_track" ? "✓" : ($0.verdict == "off_track" ? "!" : ($0.verdict == "mixed" ? "~" : "")) } ?? ""
                h += "<td align=\"center\" style=\"height:30px;background:\(color);border-radius:7px;font-size:13px;font-weight:800;color:\(card);\">\(mark)</td>"
            }
            h += "</tr>"
        }
        h += "</table><div style=\"margin-top:8px;font-size:12.5px;color:\(ink2);\">"
        h += "<span style=\"color:\(on);\">■</span> On track \(counts["on_track"] ?? 0) &nbsp; <span style=\"color:\(mixed);\">■</span> Mixed \(counts["mixed"] ?? 0) &nbsp; <span style=\"color:\(off);\">■</span> Off track \(counts["off_track"] ?? 0)</div>"
        return h + "</td></tr>"
    }

    private static func topSources(_ r: Report) -> String {
        let rows = Array(r.sources.prefix(10))
        guard let top = rows.first?.time, top > 0 else { return "" }
        var h = heading("Top apps and sites", detail: "this week")
        h += "<tr><td style=\"background:\(card);border-radius:18px;padding:8px 16px 14px;\">"
        for (i, s) in rows.enumerated() {
            let c = RichEmail.hex(RichEmail.categoryHex(s.category))
            h += "<table role=\"presentation\" width=\"100%\" style=\"margin-top:10px;\"><tr>"
            h += "<td width=\"22\" style=\"font-size:13px;font-weight:700;color:\(i < 3 ? ink : ink3);\">\(i + 1)</td>"
            h += "<td style=\"font-size:14px;color:\(ink);\">\(RichEmail.esc(s.label)) <span style=\"font-size:12px;color:\(ink3);\">\(RichEmail.esc(s.category.displayName))</span></td>"
            h += "<td align=\"right\" style=\"font-size:13.5px;font-weight:700;color:\(ink2);white-space:nowrap;\">\(Fmt.duration(s.time))</td></tr></table>"
            h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top:5px;\"><tr><td width=\"22\"></td>"
            h += "<td width=\"\(max(2, Int(s.time / top * 100)))%\" style=\"height:4px;background:\(c);border-radius:2px;font-size:0;\">&nbsp;</td><td style=\"font-size:0;\">&nbsp;</td></tr></table>"
        }
        return h + "</td></tr>"
    }

    // MARK: Scores

    /// Consecutive days, ending today (or yesterday while today is young), where most engaged time went to
    /// work, learning and reading.
    static func focusStreak(_ week: Report) -> Int {
        var streak = 0
        for (i, b) in week.buckets.reversed().enumerated() {
            let total = b.byGroup.values.reduce(0, +)
            let prod = b.byGroup.filter { AllocationGroup.productive.contains($0.key) }.values.reduce(0, +)
            let good = total >= 30 * 60 && prod / total >= 0.5
            if good { streak += 1 } else if i == 0 { continue } else { break }
        }
        return streak
    }

    static func onTrackStreak(_ checkins: [AtlasStore.Checkin], now: Date) -> Int {
        var n = 0
        for c in checkins.sorted(by: { $0.ts > $1.ts }) {
            if c.verdict == "on_track" { n += 1 } else if c.verdict == "insufficient_data" { continue } else { break }
        }
        return n
    }

    static func peakCell(_ r: Report) -> String? {
        var best: (Int, Int, TimeInterval)?
        for d in 0..<7 { for h in 0..<24 {
            let v = AllocationGroup.productive.reduce(0) { $0 + (r.heat[$1]?[d][h] ?? 0) }
            if v > (best?.2 ?? 0) { best = (d, h, v) }
        } }
        guard let best else { return nil }
        return "\(["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"][best.0]) around \(hourName(best.1))"
    }

    private static func nearestSlot(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        let t = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        return [9, 12, 15, 18, 21].min { abs(Double($0) - t) < abs(Double($1) - t) } ?? 9
    }

    static func weekday(_ d: Date) -> String { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f.string(from: d) }

    static func hourName(_ h: Int) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("j")
        return f.string(from: Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date())
    }

    /// Category colours, softened toward the card like the Reports screen.
    static func muted(_ v: UInt32) -> String {
        let bg: UInt32 = 0x1A1A1E
        func mix(_ s: UInt32) -> UInt32 { let a = (v >> s) & 0xFF, b = (bg >> s) & 0xFF; return UInt32(Double(a) * 0.72 + Double(b) * 0.28) }
        return RichEmail.hex((mix(16) << 16) | (mix(8) << 8) | mix(0))
    }

    // MARK: Animated charts

    private struct Canvas {
        let ctx: CGContext
        let space = CGColorSpaceCreateDeviceRGB()
        init?(w: Int, h: Int) {
            guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx = c
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        }
        func color(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a])!
        }
        func fill(_ r: CGRect, _ c: CGColor, radius: CGFloat = 0) {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2, r.height / 2), cornerHeight: min(radius, r.width / 2, r.height / 2), transform: nil))
            ctx.setFillColor(c); ctx.fillPath()
        }
        func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat = 21, color: UInt32 = 0x8F8F99, align: CGFloat = 0) {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let str = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                 NSAttributedString.Key(kCTForegroundColorAttributeName as String): self.color(color)])
            let line = CTLineCreateWithAttributedString(str)
            let w = CTLineGetTypographicBounds(line, nil, nil, nil)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x - CGFloat(w) * align, y: y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    private static func encodeGIF(_ frames: [(CGImage, Double)]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (img, delay) in frames {
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func mutedHex(_ v: UInt32) -> UInt32 { UInt32(muted(v).dropFirst(), radix: 16) ?? v }

    /// Stacked hours per day; bars rise one after another.
    static func barsGIF(_ r: Report) -> Data? {
        guard !r.buckets.isEmpty else { return nil }
        let W = 1072, H = 440, left: CGFloat = 64, top: CGFloat = 20, bottom: CGFloat = 380
        let maxHours = max(2, ceil(r.buckets.map { $0.byGroup.filter { $0.key != .idleOrUncertain }.values.reduce(0, +) / 3600 }.max() ?? 0))
        let step = maxHours <= 4 ? 1.0 : (maxHours <= 8 ? 2.0 : 4.0)
        let top2 = ceil(maxHours / step) * step
        let n = CGFloat(r.buckets.count)
        let slot = (CGFloat(W) - left - 8) / n
        let barW = slot * (r.buckets.count > 10 ? 0.7 : 0.56)
        let frames = 30
        var out: [(CGImage, Double)] = []
        for f in 0..<frames {
            guard let c = Canvas(w: W, h: H) else { return nil }
            c.fill(CGRect(x: 0, y: 0, width: W, height: H), c.color(0x1A1A1E))
            var y = 0.0
            while y <= top2 + 0.001 {
                let py = bottom - CGFloat(y / top2) * (bottom - top)
                c.fill(CGRect(x: left, y: py, width: CGFloat(W) - left - 8, height: 1.5), c.color(0xFFFFFF, 0.08))
                c.text("\(Int(y))h", x: left - 14, y: py + 7, size: 19, align: 1)
                y += step
            }
            for (i, b) in r.buckets.enumerated() {
                let delay = Double(i) / Double(max(r.buckets.count - 1, 1)) * 12
                let raw = min(max((Double(f) - delay) / 12, 0), 1)
                let p = 1 - pow(1 - raw, 3)
                let x = left + CGFloat(i) * slot + (slot - barW) / 2
                var base = bottom
                for g in AllocationGroup.charted {
                    guard let v = b.byGroup[g], v >= 60 else { continue }
                    let hgt = CGFloat(v / 3600 / top2) * (bottom - top) * CGFloat(p)
                    guard hgt > 0.5 else { continue }
                    c.fill(CGRect(x: x, y: base - hgt, width: barW, height: max(hgt - 3, 1)), c.color(mutedHex(groupHex(g))), radius: 6)
                    base -= hgt
                }
                if r.buckets.count <= 10 || i % 5 == 0 {
                    let label = r.hourly ? hourName(Calendar.current.component(.hour, from: b.start)) : (r.buckets.count <= 10 ? weekday(b.start) : { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("dMMM"); return f.string(from: b.start) }())
                    c.text(label, x: x + barW / 2, y: bottom + 36, size: 20, align: 0.5)
                }
            }
            guard let img = c.ctx.makeImage() else { return nil }
            out.append((img, f == frames - 1 ? 4.0 : 0.04))
        }
        return encodeGIF(out)
    }

    /// Weekday × hour of work, learning and reading; cells light up in a diagonal sweep and the peak is ringed.
    static func heatGIF(_ r: Report) -> Data? {
        let grid = (0..<7).map { d in (0..<24).map { h in AllocationGroup.productive.reduce(0) { $0 + (r.heat[$1]?[d][h] ?? 0) } } }
        let peak = grid.flatMap { $0 }.max() ?? 0
        guard peak > 0 else { return nil }
        let used = (0..<24).filter { h in grid.contains { $0[h] > 0 } }
        let hours = Array(min(7, used.min() ?? 7)...max(23, used.max() ?? 23))
        let W = 1072, left: CGFloat = 70, gap: CGFloat = 5
        let cw = (CGFloat(W) - left - gap * CGFloat(hours.count - 1)) / CGFloat(hours.count)
        let ch: CGFloat = 40
        let H = Int(7 * (ch + gap) + 44)
        var best = (0, 0)
        for d in 0..<7 { for h in 0..<24 where grid[d][h] == peak { best = (d, h) } }
        let frames = 28
        var out: [(CGImage, Double)] = []
        for f in 0..<frames {
            guard let c = Canvas(w: W, h: H) else { return nil }
            c.fill(CGRect(x: 0, y: 0, width: W, height: H), c.color(0x1A1A1E))
            for d in 0..<7 {
                let y = CGFloat(d) * (ch + gap)
                c.text(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][d], x: 0, y: y + 27, size: 19)
                for (j, h) in hours.enumerated() {
                    let x = left + CGFloat(j) * (cw + gap)
                    let delay = Double(d + j) / Double(7 + hours.count) * 16
                    let p = min(max((Double(f) - delay) / 6, 0), 1)
                    let v = grid[d][h]
                    let level = v / peak
                    let color = v > 0 ? c.color(0xF4F4F6, CGFloat(0.12 + 0.88 * level * p)) : c.color(0x26262B)
                    c.fill(CGRect(x: x, y: y, width: cw, height: ch), color, radius: 7)
                    if f >= 20, (d, h) == best {
                        c.ctx.addPath(CGPath(roundedRect: CGRect(x: x - 2, y: y - 2, width: cw + 4, height: ch + 4), cornerWidth: 9, cornerHeight: 9, transform: nil))
                        c.ctx.setStrokeColor(c.color(0x3DD68C)); c.ctx.setLineWidth(3.5); c.ctx.strokePath()
                    }
                }
            }
            for (j, h) in hours.enumerated() where h % 3 == 0 {
                c.text(hourName(h), x: left + CGFloat(j) * (cw + gap), y: CGFloat(H) - 8, size: 18)
            }
            guard let img = c.ctx.makeImage() else { return nil }
            out.append((img, f == frames - 1 ? 4.0 : 0.05))
        }
        return encodeGIF(out)
    }
}
