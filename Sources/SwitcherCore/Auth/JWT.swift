import Foundation

/// Read-only JWT payload inspection (no signature verification; we only display claims the vendor already
/// shows the user, such as the account email and plan).
public enum JWT {
    public static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func expiry(_ token: String) -> Date? {
        guard let payload = decodePayload(token) else { return nil }
        if let exp = payload["exp"] as? Double { return Date(timeIntervalSince1970: exp) }
        if let exp = payload["exp"] as? Int { return Date(timeIntervalSince1970: TimeInterval(exp)) }
        return nil
    }
}
