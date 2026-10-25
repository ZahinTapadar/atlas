import Foundation

/// Shared JSON coders. Internal persistence uses epoch seconds; anything human- or model-facing uses ISO-8601.
public enum AtlasJSON {
    public static func encoder(iso: Bool = false, pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = iso ? .iso8601 : .secondsSince1970
        // Sorted keys keep payloads byte-stable (reproducible requests, cache-friendly prompts).
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder(iso: Bool = false) -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = iso ? .iso8601 : .secondsSince1970
        return d
    }

    public static func string<T: Encodable>(_ v: T, iso: Bool = false, pretty: Bool = false) throws -> String {
        String(decoding: try encoder(iso: iso, pretty: pretty).encode(v), as: UTF8.self)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from s: String, iso: Bool = false) throws -> T {
        try decoder(iso: iso).decode(type, from: Data(s.utf8))
    }
}

extension AtlasSettings {
    /// Decode settings saved by an older build: unknown keys are ignored and missing keys take defaults.
    public static func decodeLenient(_ json: String) -> AtlasSettings {
        guard let defaults = try? JSONSerialization.jsonObject(with: AtlasJSON.encoder().encode(AtlasSettings())) as? [String: Any],
              let stored = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return AtlasSettings()
        }
        let merged = defaults.merging(stored.filter { defaults[$0.key] != nil }) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let s = try? AtlasJSON.decoder().decode(AtlasSettings.self, from: data) else {
            return AtlasSettings()
        }
        return s
    }
}
