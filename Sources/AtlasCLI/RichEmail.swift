import AtlasCore
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The check-in email as the app looks: a dark card with the verdict, an animated GIF of the day's
/// ten-minute cells, the to-dos and where the time went. Mail clients don't run scripts or CSS animation,
/// but every one of them (Gmail on Android included) plays GIFs, so the motion lives in the image.
enum RichEmail {
    struct Content {
        var subject: String
        var text: String
        var html: String
        var gif: Data?
    }

    // Dark palette, mirroring the app (Theme.swift / Components.swift).
    static let ground = "#0e0e10", card = "#1a1a1e", raised = "#222227", line = "#2a2a30"
    static let ink = "#f4f4f6", ink2 = "#a1a1aa", ink3 = "#8f8f99"

    static func verdictColor(_ v: String?) -> String {
        switch v { case "on_track": "#3dd68c"; case "mixed": "#f5b342"; case "off_track": "#ff6b6b"; default: "#a1a1aa" }
    }

    static func verdictTitle(_ v: String?) -> String {
        switch v { case "on_track": "On track"; case "mixed": "Mixed"; case "off_track": "Off track"; case "insufficient_data": "Not enough data"; default: "Check-in" }
    }

    static func categoryHex(_ c: ActivityCategory) -> UInt32 {
        switch c {
        case .focusedWork: 0x8B8BF5
        case .coding: 0x5C8DFF
        case .research: 0x2DD4C4
        case .reading: 0x38BDF8
        case .educationalVideo: 0x9BD94A
        case .entertainmentVideo: 0xF472B6
        case .socialMedia: 0xFB923C
        case .gaming: 0xA78BFA
        case .communication: 0xF2C94C
        case .administrative: 0xA8A29E
        case .personalOrganization: 0x34D399
        case .breakTime: 0x64748B
        case .idle: 0x2E2E34
        case .unknown: 0xC9A55A
        }
    }

    static func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

    // MARK: Build

    static func build(checkin: AtlasStore.Checkin?, fallbackSubject: String, fallbackBody: String,
                      events: [ActivityEvent], reasons: [AtlasStore.TodoReason], now: Date = Date()) -> Content {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: now)
        let normalized = TimeAccounting.normalized(events, from: dayStart, to: now)
        let cells = ribbonCells(normalized, now: now)
        let gif = cells.isEmpty ? nil : ribbonGIF(cells)
        let text = checkin?.body ?? fallbackBody
        let parts = CheckinParts(text)
        let verdict = checkin?.verdict
        let vc = verdictColor(verdict)
        let time = DateFormatter.localizedString(from: checkin?.ts ?? now, dateStyle: .none, timeStyle: .short)
        let day = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEEdMMMM"); return f.string(from: now) }()

        var totals: [(ActivityCategory, TimeInterval)] = TimeAccounting.totals(normalized)
            .filter { $0.key.allocationGroup != .idleOrUncertain }
            .map { ($0.key, $0.value.observed) }.filter { $0.1 >= 60 }
        totals.sort { $0.1 > $1.1 }
        let engaged = totals.reduce(0) { $0 + $1.1 }

        var h = ""
        h += "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
        h += "<meta name=\"color-scheme\" content=\"dark\"><meta name=\"supported-color-schemes\" content=\"dark\"><title>\(esc(fallbackSubject))</title></head>"
        h += "<body style=\"margin:0;padding:0;background:\(ground);\">"
        h += "<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;\">\(esc(parts.headline))</div>"
        h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"background:\(ground);\"><tr><td align=\"center\" style=\"padding:20px 12px 32px;\">"
        h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"max-width:600px;table-layout:fixed;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',Roboto,'Segoe UI',Helvetica,Arial,sans-serif;color:\(ink);\">"

        // Masthead
        h += "<tr><td style=\"padding:4px 6px 16px;\"><table role=\"presentation\" width=\"100%\"><tr>"
        h += "<td style=\"font-size:13px;font-weight:700;letter-spacing:3px;color:\(ink);\">ATLAS</td>"
        h += "<td align=\"right\" style=\"font-size:13px;color:\(ink3);\">\(esc(day)) · \(esc(time))</td></tr></table></td></tr>"

        // Verdict
        h += "<tr><td style=\"background:\(card);border:1px solid \(vc)40;border-radius:22px;padding:26px 26px 22px;background-image:linear-gradient(180deg,\(vc)24,\(vc)0a);\">"
        h += "<div style=\"font-size:36px;line-height:1.05;font-weight:800;letter-spacing:-1px;color:\(vc);\">\(esc(verdictTitle(verdict)))</div>"
        if !parts.headline.isEmpty {
            h += "<div style=\"font-size:18px;line-height:1.4;font-weight:600;color:\(ink);margin-top:12px;\">\(esc(parts.headline))</div>"
        }
        if !parts.evidence.isEmpty {
            h += "<table role=\"presentation\" style=\"margin-top:12px;\">"
            for e in parts.evidence.prefix(5) {
                h += "<tr><td valign=\"top\" style=\"padding:3px 10px 3px 0;\"><div style=\"width:6px;height:6px;border-radius:3px;background:\(vc);margin-top:7px;\"></div></td>"
                h += "<td style=\"font-size:14.5px;line-height:1.5;color:\(ink2);padding:2px 0;\">\(esc(e))</td></tr>"
            }
            h += "</table>"
        }
        if let next = parts.next {
            h += "<div style=\"margin-top:16px;background:rgba(0,0,0,0.28);border-radius:14px;padding:14px 16px;\">"
            h += "<div style=\"font-size:12px;font-weight:700;letter-spacing:1px;color:\(vc);margin-bottom:6px;\">NEXT</div>"
            for step in next.components(separatedBy: "\n") where !step.isEmpty {
                h += "<div style=\"font-size:15.5px;line-height:1.45;font-weight:600;color:\(ink);padding:2px 0;\">→ \(esc(step))</div>"
            }
            h += "</div>"
        }
        h += "</td></tr>"

        // The day so far (animated)
        if gif != nil {
            h += section("The day so far", detail: engaged > 0 ? "\(Fmt.duration(engaged)) engaged" : nil)
            h += "<tr><td style=\"background:\(card);border-radius:18px;padding:16px 16px 12px;\">"
            h += "<img src=\"cid:day@atlas\" width=\"100%\" alt=\"Today in ten-minute cells, coloured by activity\" style=\"display:block;width:100%;max-width:536px;height:auto;border:0;\">"
            let legend = totals.prefix(5).map { (c, t) in
                "<span style=\"display:inline-block;margin:8px 14px 0 0;font-size:12.5px;color:\(ink2);\"><span style=\"display:inline-block;width:8px;height:8px;border-radius:4px;background:\(hex(categoryHex(c)));margin-right:6px;\"></span>\(esc(c.displayName)) <span style=\"color:\(ink3);\">\(Fmt.duration(t))</span></span>"
            }.joined()
            h += "<div>\(legend)</div></td></tr>"
        }

        // To-dos
        if let todos = checkin?.todos, !todos.isEmpty {
            let done = todos.filter { $0.status == "done" }.count
            h += section("Today's to-dos", detail: "\(done) of \(todos.count) done")
            h += "<tr><td style=\"background:\(card);border-radius:18px;padding:8px 18px;\"><table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\">"
            for (i, t) in todos.prefix(20).enumerated() {
                let (mark, color, fill) = statusMark(t.status)
                let border = i == 0 ? "" : "border-top:1px solid \(line);"
                h += "<tr><td valign=\"top\" style=\"\(border)padding:11px 12px 11px 0;width:22px;\">"
                h += "<div style=\"width:18px;height:18px;border-radius:9px;\(fill ? "background:\(color);" : "border:2px solid \(color);box-sizing:border-box;")text-align:center;font-size:12px;line-height:18px;font-weight:800;color:\(card);\">\(mark)</div></td>"
                h += "<td style=\"\(border)padding:11px 0;\">"
                h += "<div style=\"font-size:15px;line-height:1.35;color:\(t.status == "done" ? ink3 : ink);\(t.status == "done" ? "text-decoration:line-through;" : "")\">\(esc(t.title))</div>"
                if let note = t.note, !note.isEmpty { h += "<div style=\"font-size:13px;color:\(ink3);margin-top:3px;\">\(esc(note))</div>" }
                if let r = reasons.first(where: { $0.key == t.thingsID || $0.title == t.title }) {
                    h += "<div style=\"font-size:13px;color:#f5b342;margin-top:4px;\">Your reason: \(esc(r.reason))</div>"
                }
                h += "</td><td align=\"right\" valign=\"top\" style=\"\(border)padding:11px 0 11px 10px;font-size:13.5px;color:\(ink2);white-space:nowrap;\">\(t.minutes.map { $0 > 0 ? Fmt.duration(TimeInterval($0 * 60)) : "" } ?? "")</td></tr>"
            }
            h += "</table></td></tr>"
        }

        // Where the time went
        if !totals.isEmpty {
            h += section("Where the time went", detail: nil)
            h += "<tr><td style=\"background:\(card);border-radius:18px;padding:16px 18px 18px;\">"
            let top = totals.first?.1 ?? 1
            for (c, t) in totals.prefix(6) {
                let pct = max(2, Int((t / top * 100).rounded()))
                h += "<table role=\"presentation\" width=\"100%\" style=\"margin-top:10px;\"><tr><td style=\"font-size:14px;color:\(ink);\">\(esc(c.displayName))</td>"
                h += "<td align=\"right\" style=\"font-size:14px;font-weight:600;color:\(ink);\">\(Fmt.duration(t))</td></tr></table>"
                h += "<table role=\"presentation\" width=\"100%\" cellpadding=\"0\" cellspacing=\"0\" style=\"margin-top:6px;\"><tr>"
                h += "<td width=\"\(pct)%\" style=\"height:5px;background:\(hex(categoryHex(c)));border-radius:3px;font-size:0;line-height:0;\">&nbsp;</td>"
                h += "<td style=\"height:5px;font-size:0;line-height:0;\">&nbsp;</td></tr></table>"
            }
            h += "</td></tr>"
        }

        h += "<tr><td style=\"padding:22px 6px 0;font-size:12px;line-height:1.5;color:\(ink3);\">Sent by ATLAS from your Mac after your scheduled Claude check-in. Your activity stays on your Mac; this email carries only this summary.</td></tr>"
        h += "</table></td></tr></table></body></html>"

        return Content(subject: fallbackSubject, text: text, html: h, gif: gif)
    }

    private static func section(_ title: String, detail: String?) -> String {
        "<tr><td style=\"padding:26px 6px 10px;\"><table role=\"presentation\" width=\"100%\"><tr><td style=\"font-size:16px;font-weight:700;color:\(ink);\">\(esc(title))</td>"
            + "<td align=\"right\" style=\"font-size:12.5px;color:\(ink3);\">\(esc(detail ?? ""))</td></tr></table></td></tr>"
    }

    private static func statusMark(_ s: String) -> (String, String, Bool) {
        switch s {
        case "done": ("✓", "#3dd68c", true)
        case "in_progress": ("", "#f5b342", false)
        case "dropped": ("–", ink3, false)
        default: ("", "#6e6e78", false)
        }
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Ribbon

    struct Cell { var start: Date; var color: UInt32?; var future: Bool }

    static func ribbonCells(_ events: [ActivityEvent], now: Date) -> [Cell] {
        let cal = Calendar.current
        guard let first = events.filter({ $0.state.isEngaged }).map(\.start).min() else { return [] }
        let start = cal.dateInterval(of: .hour, for: first)?.start ?? first
        let endHour = cal.date(byAdding: .hour, value: 1, to: cal.dateInterval(of: .hour, for: now)?.start ?? now) ?? now
        let end = max(endHour, start.addingTimeInterval(4 * 3600))
        var out: [Cell] = []
        var t = start
        while t < end {
            let iv = DateInterval(start: t, duration: 600)
            var byCat: [ActivityCategory: TimeInterval] = [:]
            var engaged: TimeInterval = 0
            for e in events where e.end > iv.start && e.start < iv.end && e.state.isEngaged {
                let overlap = min(e.end, iv.end).timeIntervalSince(max(e.start, iv.start))
                engaged += overlap
                byCat[e.privacy == .excluded ? .unknown : e.classification.category, default: 0] += overlap
            }
            let best = byCat.max { $0.value < $1.value }?.key
            out.append(Cell(start: t, color: engaged > 180 ? best.map(categoryHex) : nil, future: t > now))
            t = t.addingTimeInterval(600)
        }
        return out
    }

    /// Cells rise in from the left, then the current one breathes. 2x resolution for sharp phones.
    static func ribbonGIF(_ cells: [Cell]) -> Data? {
        let W = 1072, H = 176, top = 14, cellH = 104, labelY = 150
        let gap: CGFloat = 5
        let n = CGFloat(cells.count)
        let cw = (CGFloat(W) - gap * (n - 1)) / n
        let current = cells.lastIndex { !$0.future }
        let reveal = 26, breathe = 14
        let frames = reveal + breathe
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let space = CGColorSpaceCreateDeviceRGB()
        func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: space, components: [CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255, a])!
        }
        let font = CTFontCreateUIFontForLanguage(.system, 21, nil)!
        let hf = DateFormatter(); hf.setLocalizedDateFormatFromTemplate("j")

        for f in 0..<frames {
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.setFillColor(rgb(0x1A1A1E)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
            ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)   // top-left origin
            for (i, c) in cells.enumerated() {
                let x = CGFloat(i) * (cw + gap)
                let delay = Double(i) / Double(max(cells.count - 1, 1)) * Double(reveal - 8)
                let raw = min(max((Double(f) - delay) / 8, 0), 1)
                let p = 1 - pow(1 - raw, 3)
                var alpha: CGFloat = 0.25 + 0.75 * p
                if f >= reveal, i == current, c.color != nil {
                    let phase = Double(f - reveal) / Double(breathe) * 2 * .pi
                    alpha = 0.55 + 0.45 * CGFloat((cos(phase) + 1) / 2)
                }
                let h = CGFloat(cellH) * CGFloat(0.35 + 0.65 * p)
                let rect = CGRect(x: x, y: CGFloat(top + cellH) - h, width: cw, height: h)
                let color: CGColor = c.future ? rgb(0x26262B, 0.6) : (c.color.map { rgb($0, alpha) } ?? rgb(0x2A2A30))
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: min(8, cw / 2), cornerHeight: min(8, cw / 2), transform: nil))
                ctx.setFillColor(color); ctx.fillPath()
            }
            // Hour labels under the cells.
            for (i, c) in cells.enumerated() where Calendar.current.component(.minute, from: c.start) == 0 {
                let label = NSAttributedString(string: hf.string(from: c.start), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x8F8F99)])
                let line = CTLineCreateWithAttributedString(label)
                ctx.saveGState()
                ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                ctx.textPosition = CGPoint(x: CGFloat(i) * (cw + gap), y: CGFloat(labelY + 8))
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
            guard let img = ctx.makeImage() else { return nil }
            let delay = f == reveal - 1 ? 0.6 : (f < reveal ? 0.04 : 0.09)
            CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Sends HTML mail through the user's own provider over SMTP with curl. The app password lives in the
/// login Keychain (service "ATLAS SMTP"), stored by the user with `atlasctl email-setup`; ATLAS never sees
/// it except to hand it to curl over stdin.
enum SMTPMail {
    static let keychainService = "ATLAS SMTP"

    static func server(for address: String) -> (url: String, startTLS: Bool)? {
        let domain = address.split(separator: "@").last.map { $0.lowercased() } ?? ""
        switch domain {
        case "gmail.com", "googlemail.com": return ("smtps://smtp.gmail.com:465", false)
        case "icloud.com", "me.com", "mac.com": return ("smtp://smtp.mail.me.com:587", true)
        default: return nil
        }
    }

    static func password(for address: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService, "-a", address, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s : nil
    }

    static func isConfigured(_ address: String) -> Bool { server(for: address) != nil && password(for: address) != nil }

    static func send(to address: String, content: RichEmail.Content) throws {
        guard let server = server(for: address), let pass = password(for: address) else {
            throw Integrations.Failure(message: "HTML email isn't set up. Run: atlasctl email-setup")
        }
        let message = mime(from: address, to: address, content: content)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-mail-\(UUID().uuidString).eml")
        try message.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var args = ["--silent", "--show-error", "--url", server.url, "--mail-from", address, "--mail-rcpt", address,
                    "--upload-file", file.path, "-K", "-"]
        if server.startTLS { args.append("--ssl-reqd") }
        p.arguments = args
        let input = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let quoted = "\(address):\(pass)".replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        input.fileHandleForWriting.write(Data("user = \"\(quoted)\"\n".utf8))
        try input.fileHandleForWriting.close()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: e, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 67 { throw Integrations.Failure(message: "The mail server rejected the app password. Run atlasctl email-setup again.") }
            throw Integrations.Failure(message: "Sending failed: \(msg)")
        }
    }

    static func mime(from: String, to: String, content: RichEmail.Content) -> Data {
        let alt = "atlas-alt-\(UUID().uuidString)", rel = "atlas-rel-\(UUID().uuidString)"
        let date = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f.string(from: Date()) }()
        func b64(_ d: Data) -> String { d.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }
        let subject = "=?UTF-8?B?\(Data(content.subject.utf8).base64EncodedString())?="
        var m = """
        From: ATLAS <\(from)>\r
        To: <\(to)>\r
        Subject: \(subject)\r
        Date: \(date)\r
        Message-ID: <\(UUID().uuidString)@atlas.local>\r
        MIME-Version: 1.0\r
        Content-Type: multipart/alternative; boundary="\(alt)"\r
        \r
        --\(alt)\r
        Content-Type: text/plain; charset=UTF-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64(Data(content.text.utf8)))\r
        --\(alt)\r
        Content-Type: multipart/related; boundary="\(rel)"\r
        \r
        --\(rel)\r
        Content-Type: text/html; charset=UTF-8\r
        Content-Transfer-Encoding: base64\r
        \r
        \(b64(Data(content.html.utf8)))\r

        """
        if let gif = content.gif {
            m += """
            --\(rel)\r
            Content-Type: image/gif; name="day.gif"\r
            Content-Transfer-Encoding: base64\r
            Content-ID: <day@atlas>\r
            Content-Disposition: inline; filename="day.gif"\r
            \r
            \(b64(gif))\r

            """
        }
        m += "--\(rel)--\r\n--\(alt)--\r\n"
        return Data(m.utf8)
    }
}

enum Fmt {
    static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }
}

enum CheckinMail {
    /// Emails the check-in to the configured address: the designed HTML version when SMTP is set up,
    /// otherwise plain text through Mail. Returns a short description of what was sent.
    static func deliver(subject: String, body: String) async throws -> String {
        let store = try readStore()
        guard let to = try await store.preference(AtlasStore.notifyEmailKey), Integrations.isPlausibleEmail(to) else {
            throw Integrations.Failure(message: "No notification email set. Run: atlasctl set-email you@example.com")
        }
        if SMTPMail.isConfigured(to) {
            try SMTPMail.send(to: to, content: try await content(store: store, subject: subject, body: body))
            return "Emailed the designed HTML check-in to \(to)."
        }
        try Integrations.sendEmail(to: to, subject: subject, body: body)
        return "Emailed plain text to \(to) (run atlasctl email-setup for the designed HTML version)."
    }

    static func content(store: AtlasStore, subject: String, body: String) async throws -> RichEmail.Content {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let latest = try await store.checkins(limit: 1).first
        // Only attach the recorded check-in when it is the one being sent (record_checkin runs just before).
        let checkin = latest.flatMap { now.timeIntervalSince($0.ts) < 45 * 60 ? $0 : nil }
        let events = try await store.events(from: start, to: now)
        let reasons = (try? await store.todoReasons(since: AtlasStore.dayKey(now))) ?? []
        return RichEmail.build(checkin: checkin, fallbackSubject: subject, fallbackBody: body, events: events, reasons: reasons, now: now)
    }
}
