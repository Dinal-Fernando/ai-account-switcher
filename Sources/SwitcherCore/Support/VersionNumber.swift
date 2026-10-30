import Foundation

/// Dotted version comparison ("2.1.314" < "2.1.400"), tolerant of suffixes like "2.1.3 (Claude Code)".
public struct VersionNumber: Comparable, Equatable, Sendable, CustomStringConvertible {
    public var components: [Int]

    public init(_ components: [Int]) { self.components = components }

    public init?(parsing text: String) {
        var found: String?
        let digits = CharacterSet(charactersIn: "0123456789.")
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx].isNumber {
                var end = idx
                while end < text.endIndex, let u = text[end].unicodeScalars.first, digits.contains(u) { end = text.index(after: end) }
                let candidate = String(text[idx..<end])
                if candidate.contains(".") { found = candidate; break }
                idx = end
            } else {
                idx = text.index(after: idx)
            }
        }
        guard let found else { return nil }
        let parts = found.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.components = parts
    }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}
