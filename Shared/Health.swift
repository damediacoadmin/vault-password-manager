import Foundation
import CryptoKit

struct HealthReport {
    var weak: [VaultItem] = []
    var reused: [[VaultItem]] = []
    var old: [VaultItem] = []
    var breached: [VaultItem] = []
    var total = 0

    var reusedCount: Int { reused.reduce(0) { $0 + $1.count } }
    var toFix: Int { Set(weak.map(\.id) + reused.flatMap { $0.map(\.id) } + breached.map(\.id)).count }

    /// 0 to 100. Breaches count triple, reuse double.
    var score: Int {
        guard total > 0 else { return 100 }
        let penalty = Double(breached.count * 3 + reusedCount * 2 + weak.count) / Double(total * 3)
        return max(0, min(100, Int((1 - penalty) * 100 - Double(old.count) / Double(total) * 5)))
    }

    var label: String {
        switch score {
        case 90...: return "Excellent"
        case 75..<90: return "Good"
        case 50..<75: return "Needs work"
        default: return "At risk"
        }
    }

    static func build(_ items: [VaultItem], breachedIDs: Set<UUID> = []) -> HealthReport {
        let logins = items.filter { $0.kind == .login && !$0.password.isEmpty }
        var r = HealthReport(total: logins.count)
        r.weak = logins.filter { PasswordGenerator.strength($0.password) == .weak }
        r.reused = Dictionary(grouping: logins, by: \.password).values.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        let twoYears = Date().addingTimeInterval(-2 * 365 * 86_400)
        r.old = logins.filter { $0.passwordChanged < twoYears }
        r.breached = logins.filter { breachedIDs.contains($0.id) }
        return r
    }
}

/// Checks passwords against Have I Been Pwned's free Pwned Passwords list using k-anonymity:
/// only the first 5 characters of each password's SHA-1 fingerprint ever leave the device,
/// and responses are padded so the server cannot tell which one matched.
enum BreachCheck {
    static func breachedIDs(_ items: [VaultItem]) async -> Set<UUID> {
        var byPrefix = [String: [(suffix: String, id: UUID)]]()
        for it in items where it.kind == .login && !it.password.isEmpty {
            let hex = Insecure.SHA1.hash(data: Data(it.password.utf8)).map { String(format: "%02X", $0) }.joined()
            byPrefix[String(hex.prefix(5)), default: []].append((String(hex.dropFirst(5)), it.id))
        }
        var hits = Set<UUID>()
        await withTaskGroup(of: Set<UUID>.self) { group in
            for (prefix, entries) in byPrefix {
                group.addTask {
                    guard let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)") else { return [] }
                    var req = URLRequest(url: url)
                    req.setValue("true", forHTTPHeaderField: "Add-Padding")
                    req.setValue("Vault-password-manager", forHTTPHeaderField: "User-Agent")
                    guard let (data, _) = try? await URLSession.shared.data(for: req),
                          let body = String(data: data, encoding: .utf8) else { return [] }
                    var found = Set<UUID>()
                    for line in body.split(whereSeparator: \.isNewline) {
                        let parts = line.split(separator: ":")
                        guard parts.count == 2, let n = Int(parts[1].trimmingCharacters(in: .whitespaces)), n > 0 else { continue }
                        for e in entries where e.suffix == parts[0] { found.insert(e.id) }
                    }
                    return found
                }
            }
            for await s in group { hits.formUnion(s) }
        }
        return hits
    }
}
