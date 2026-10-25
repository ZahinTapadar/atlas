import Foundation
import os

/// Diagnostic logging that never records activity content. Messages carry identifiers, counts,
/// states and error categories only; anything user-derived must go through `redact`.
public enum AtlasLog {
    public static let tracker = Logger(subsystem: "com.atlas.tracker", category: "tracker")
    public static let agent = Logger(subsystem: "com.atlas.tracker", category: "agent")
    public static let storage = Logger(subsystem: "com.atlas.tracker", category: "storage")
    public static let connectors = Logger(subsystem: "com.atlas.tracker", category: "connectors")

    /// Strip anything that may contain personal content (titles, URLs, domains, emails, paths) from a diagnostic string.
    public static func redact(_ s: String) -> String {
        var out = s
        let patterns = [
            #"https?://\S+"#,                                   // URLs
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,  // emails
            #"/Users/[^\s/]+"#,                                 // home paths
            #"“[^”]*”"#, #"\"[^\"]*\""#,                        // quoted titles
            #"\b(?:[a-z0-9-]+\.)+(?:com|org|net|io|dev|app|ai|co|edu|gov|tv|me)\b"#, // domains
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "‹redacted›", options: [.regularExpression, .caseInsensitive])
        }
        return out
    }
}
