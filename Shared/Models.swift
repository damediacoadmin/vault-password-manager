import Foundation

enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case login, card, bank, identity, note, personal
    var id: String { rawValue }

    var label: String {
        switch self {
        case .login: return "Logins"
        case .card: return "Cards"
        case .bank: return "Bank accounts"
        case .identity: return "IDs"
        case .note: return "Notes"
        case .personal: return "Personal info"
        }
    }

    var singular: String {
        switch self {
        case .login: return "Login"
        case .card: return "Card"
        case .bank: return "Bank account"
        case .identity: return "ID"
        case .note: return "Secure note"
        case .personal: return "Personal info"
        }
    }

    var symbol: String {
        switch self {
        case .login: return "key"
        case .card: return "creditcard"
        case .bank: return "building.columns"
        case .identity: return "person.text.rectangle"
        case .note: return "note.text"
        case .personal: return "person.crop.circle"
        }
    }

    /// Only logins can ever be handed to an AI assistant.
    var aiEligible: Bool { self == .login }
}

struct PasswordChange: Codable, Hashable {
    var password: String
    var changed: Date
}

struct VaultItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: ItemKind = .login
    var title: String = ""
    var username: String = ""
    var password: String = ""
    var urls: [String] = []
    var otp: String = ""            // otpauth:// URL or bare base32 secret
    var notes: String = ""
    var fields: [Field] = []        // extra labelled values (card number, ID number...)
    var collection: String = ""
    var favorite: Bool = false
    var aiAllowed: Bool = true      // only honoured for logins
    var created: Date = Date()
    var modified: Date = Date()
    var passwordChanged: Date = Date()
    var lastUsed: Date?
    var history: [PasswordChange] = []
    var passkeys: [Passkey]? = nil

    struct Field: Codable, Hashable, Identifiable {
        var id: UUID = UUID()
        var label: String
        var value: String
        var secret: Bool = false
    }

    var primaryHost: String? { urls.compactMap(Domain.host(from:)).first }

    /// Friendly name for lists: "google.com" or "accounts.google.com" titles become "Google".
    var displayName: String {
        let t = title.trimmingCharacters(in: .whitespaces)
        let looksLikeHost = !t.isEmpty && !t.contains(" ") && t.contains(".")
        if !t.isEmpty && !looksLikeHost { return t }
        let host = Domain.host(from: t) ?? primaryHost
        guard let h = host else { return t.isEmpty ? (username.isEmpty ? "Untitled" : username) : t }
        if h.allSatisfy({ $0.isNumber || $0 == "." }) { return h }          // IP address
        let first = Domain.base(h).split(separator: ".").first.map(String.init) ?? h
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// The part before the main domain, when it helps tell logins apart: "accounts" for accounts.google.com.
    var hostHint: String? {
        guard kind == .login, let h = primaryHost else { return nil }
        let base = Domain.base(h)
        guard h != base, h.hasSuffix(base) else { return nil }
        let sub = String(h.dropLast(base.count + 1))
        return sub.isEmpty || sub == "www" || sub == "login" ? nil : sub
    }

    var subtitle: String {
        switch kind {
        case .login: return username.isEmpty ? (primaryHost ?? "") : username
        case .card:
            if let n = fields.first(where: { $0.label == "Number" })?.value, n.count >= 4 { return "Ending in \(n.suffix(4))" }
            return ""
        case .bank:
            if let n = fields.first(where: { $0.label == "Account number" })?.value, n.count >= 4 { return "Ending in \(n.suffix(4))" }
            return ""
        case .identity, .personal: return fields.first?.label ?? ""
        case .note: return notes.split(separator: "\n").first.map(String.init) ?? ""
        }
    }

    mutating func setPassword(_ new: String) {
        guard new != password else { return }
        if !password.isEmpty { history.insert(PasswordChange(password: password, changed: passwordChanged), at: 0) }
        password = new
        passwordChanged = Date()
        modified = Date()
    }
}

struct AIEvent: Codable, Identifiable, Hashable {
    enum Result: String, Codable { case waiting, allowedOnce, allowedWindow, denied, blocked, notFound, rateLimited }
    var id: UUID = UUID()
    var date: Date = Date()
    var client: String
    var site: String
    var reason: String
    var result: Result

    var resultText: String {
        switch result {
        case .waiting: return "Waiting"
        case .allowedOnce: return "Allowed once"
        case .allowedWindow: return "15 minutes"
        case .denied: return "Denied by you"
        case .blocked: return "Blocked"
        case .notFound: return "No match"
        case .rateLimited: return "Paused, too many"
        }
    }
}

/// Everything that gets encrypted. Never written to disk in this form.
struct VaultPayload: Codable {
    var version: Int = 1
    var items: [VaultItem] = []
    var aiLog: [AIEvent] = []
    var aiEnabled: Bool = true
    var autoLockSeconds: Int = 60
    var deleted: [String: Date]? = nil      // tombstones so deletions sync
    var devices: [SyncedDevice]? = nil     // devices that share this vault
}

struct SyncedDevice: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var platform: String     // "iPhone" or "Mac"
    var lastSeen: Date
}

enum Domain {
    /// Lower-cased host without "www.", from a URL or bare domain.
    static func host(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let h = URL(string: withScheme)?.host, h.contains(".") else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The registrable part ("accounts.google.com" -> "google.com"). Simple two-label rule
    /// with a short list of common two-part suffixes.
    static func base(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        let twoPart: Set<String> = ["co.uk", "com.au", "co.jp", "com.br", "co.nz", "org.uk", "gov.uk", "com.mx", "co.in"]
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoPart.contains(lastTwo) { return parts.suffix(3).joined(separator: ".") }
        return lastTwo
    }

    /// True when a saved login belongs on the requested site. Same registrable domain only,
    /// so a look-alike phishing domain never matches.
    static func matches(saved: String, requested: String) -> Bool {
        guard let s = host(from: saved), let r = host(from: requested) else { return false }
        return base(s) == base(r)
    }
}
