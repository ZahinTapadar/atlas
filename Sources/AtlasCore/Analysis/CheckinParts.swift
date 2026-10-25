import Foundation

/// Splits a check-in's markdown into its verdict sentence, evidence bullets and "Next:" line.
public struct CheckinParts: Sendable {
    public var headline: String
    public var evidence: [String]
    public var next: String?

    public init(_ body: String) {
        var headline = ""
        var evidence: [String] = []
        var next: String?
        var nextLines: [String] = []
        var inNext = false
        for raw in body.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            line = line.replacingOccurrences(of: "**", with: "")
            if line.lowercased().hasPrefix("next:") {
                inNext = true
                let rest = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { nextLines.append(rest) }
            } else if inNext {
                // Steps listed under "Next:" as "1. …" or "- …".
                let step = line.replacingOccurrences(of: #"^(\d+[.)]|[-•*])\s*"#, with: "", options: .regularExpression)
                nextLines.append(step)
            } else if line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") {
                evidence.append(String(line.dropFirst(2)))
            } else if headline.isEmpty {
                headline = line
            } else {
                evidence.append(line)
            }
        }
        // Drop a leading "On track:" style prefix: the verdict word is set separately.
        if let colon = headline.firstIndex(of: ":"), headline.distance(from: headline.startIndex, to: colon) < 20 {
            headline = String(headline[headline.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if let first = headline.first, first.isLowercase { headline = first.uppercased() + headline.dropFirst() }
        if !nextLines.isEmpty { next = nextLines.joined(separator: "\n") }
        self.headline = headline
        self.evidence = evidence
        self.next = next
    }
}
