import Foundation
import Security

enum PasswordGenerator {
    struct Options: Equatable {
        enum Style: String, CaseIterable { case words = "Words", characters = "Characters" }
        var style: Style = .words
        var wordCount = 5
        var capitals = true
        var number = true
        var length = 20
        var symbols = true
    }

    static let words: [String] = {
        guard let url = Bundle.main.url(forResource: "wordlist", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return fallbackWords }
        let list = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        return list.count > 1000 ? list : fallbackWords
    }()

    static let wordSet = Set(words)

    private static let fallbackWords = ["harbor", "tangle", "velvet", "orbit", "maple", "canyon", "ember", "pilot", "quartz", "river",
                                        "saddle", "timber", "violet", "walnut", "zephyr", "anchor", "breeze", "cobalt", "dune", "falcon"]

    /// Uniform random integer in 0..<upper from the system's secure generator.
    static func uniform(_ upper: Int) -> Int {
        precondition(upper > 0)
        let limit = UInt32.max - UInt32.max % UInt32(upper)
        while true {
            var v: UInt32 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &v)
            if v < limit { return Int(v % UInt32(upper)) }
        }
    }

    static func make(_ o: Options) -> String {
        switch o.style {
        case .words:
            var parts = (0..<max(3, o.wordCount)).map { _ in words[uniform(words.count)] }
            if o.capitals {
                // Capitalise about half the words, at least one.
                var any = false
                for i in parts.indices where uniform(2) == 1 { parts[i] = parts[i].capitalized; any = true }
                if !any { let i = uniform(parts.count); parts[i] = parts[i].capitalized }
            }
            if o.number { parts.insert(String(uniform(10)), at: 1 + uniform(parts.count - 1)) }
            return parts.joined(separator: "-")
        case .characters:
            let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"),
                digits = Array("23456789"), sym = Array("!#$%&*+-=?@^_")
            var pools = [lower, upper, digits]
            if o.symbols { pools.append(sym) }
            let all = pools.flatMap { $0 }
            let n = max(12, o.length)
            var chars = pools.map { $0[uniform($0.count)] }            // one from each pool
            while chars.count < n { chars.append(all[uniform(all.count)]) }
            for i in stride(from: chars.count - 1, to: 0, by: -1) { chars.swapAt(i, uniform(i + 1)) }
            return String(chars)
        }
    }

    /// Rough strength in bits, used for the meter and Password Health.
    static func entropy(_ p: String) -> Double {
        if p.isEmpty { return 0 }
        let parts = p.split(separator: "-")
        if parts.count >= 3, parts.allSatisfy({ $0.count >= 1 }) {
            let wordParts = parts.filter { $0.allSatisfy(\.isLetter) }
            if wordParts.count >= 3, wordParts.allSatisfy({ wordSet.contains($0.lowercased()) }) {
                return Double(wordParts.count) * log2(Double(words.count)) + (parts.count > wordParts.count ? 3.3 : 0) + Double(wordParts.count)
            }
        }
        var pool = 0
        if p.contains(where: \.isLowercase) { pool += 26 }
        if p.contains(where: \.isUppercase) { pool += 26 }
        if p.contains(where: \.isNumber) { pool += 10 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 30 }
        var bits = Double(p.count) * log2(Double(max(pool, 10)))
        // Penalise repeats and common patterns.
        let unique = Set(p.lowercased()).count
        if unique < p.count / 2 { bits *= 0.6 }
        let lower = p.lowercased()
        for common in ["password", "1234", "qwerty", "letmein", "admin", "welcome", "abc", "1111", "iloveyou"] where lower.contains(common) { bits *= 0.4 }
        return bits
    }

    enum Strength: String { case weak = "Weak", fair = "Fair", strong = "Strong", veryStrong = "Very strong" }

    static func strength(_ p: String) -> Strength {
        switch entropy(p) {
        case ..<45: return .weak
        case ..<60: return .fair
        case ..<80: return .strong
        default: return .veryStrong
        }
    }
}
