import Foundation
import Compression

/// Reads a Dashlane export (the .zip of CSV files, a single CSV, or the older JSON export)
/// entirely in memory and turns it into vault items. Nothing is written to disk.
enum DashlaneImport {
    struct Result: Identifiable {
        let id = UUID()
        var items: [VaultItem] = []
        var files: [String] = []
        var passkeySites: [String] = []
        var skipped = 0

        func count(_ k: ItemKind) -> Int { items.filter { $0.kind == k }.count }
        var otpCount: Int { items.filter { !$0.otp.isEmpty }.count }
    }

    enum ImportError: LocalizedError {
        case unreadable, nothingFound
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file is not a Dashlane export Vault can read."
            case .nothingFound: return "No items were found in this file."
            }
        }
    }

    static func read(data: Data, filename: String) throws -> Result {
        var files: [(String, Data)] = []
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            files = try Zip.entries(data).filter { $0.0.lowercased().hasSuffix(".csv") || $0.0.lowercased().hasSuffix(".json") }
        } else {
            files = [(filename, data)]
        }
        var r = Result()
        for (name, d) in files {
            let base = (name as NSString).lastPathComponent
            if base.lowercased().hasSuffix(".json") {
                try parseJSON(d, into: &r)
            } else {
                guard let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) else { continue }
                parseCSV(text, name: base.lowercased(), into: &r)
            }
            r.files.append(base)
        }
        if r.items.isEmpty { throw ImportError.nothingFound }
        return r
    }

    // MARK: CSV

    static func parseCSV(_ text: String, name: String, into r: inout Result) {
        let rows = CSV.parse(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return }
        let kind = detect(name: name, header: header)
        for row in rows.dropFirst() where row.contains(where: { !$0.isEmpty }) {
            var rec = [String: String]()
            for (i, h) in header.enumerated() where i < row.count { rec[h] = row[i] }
            if let item = makeItem(kind: kind, rec) { r.items.append(item) } else { r.skipped += 1 }
            if kind == .login, let pk = rec["passkey"] ?? rec["passkeys"], !pk.isEmpty, let host = rec["url"].flatMap(Domain.host) {
                r.passkeySites.append(host)
            }
        }
    }

    private static func detect(name: String, header: [String]) -> ItemKind {
        if name.contains("credential") || header.contains("password") && header.contains("url") { return .login }
        if name.contains("securenote") || name.contains("note") { return .note }
        if name.contains("payment") || header.contains("cc_number") || header.contains("account_number") { return .card }
        if name.contains("ids") || header.contains("place_of_issue") { return .identity }
        if name.contains("personal") { return .personal }
        return header.contains("password") ? .login : .note
    }

    private static let labels: [String: String] = [
        "account_name": "Name on account", "account_holder": "Account holder", "cc_number": "Number", "code": "Security code",
        "expiration_month": "Expiry month", "expiration_year": "Expiry year", "routing_number": "Routing number",
        "account_number": "Account number", "issuing_bank": "Bank", "country": "Country", "number": "Number", "name": "Name",
        "issue_date": "Issued", "expiration_date": "Expires", "place_of_issue": "Issued in", "state": "State",
        "first_name": "First name", "middle_name": "Middle name", "last_name": "Last name", "email": "Email",
        "phone_number": "Phone", "address": "Address", "city": "City", "zip": "ZIP code", "date_of_birth": "Birthday",
        "job_title": "Job title", "login": "Login", "iban": "IBAN", "bic": "BIC", "owner": "Owner"
    ]
    private static let secretKeys: Set<String> = ["cc_number", "code", "account_number", "routing_number", "number", "iban"]

    static func makeItem(kind: ItemKind, _ rec: [String: String]) -> VaultItem? {
        var it = VaultItem()
        it.kind = kind
        it.collection = rec["category"] ?? ""
        it.notes = rec["note"] ?? rec["notes"] ?? ""
        switch kind {
        case .login:
            it.title = rec["title"] ?? rec["name"] ?? ""
            it.username = [rec["username"], rec["login"], rec["email"], rec["username2"], rec["username3"]].compactMap { $0 }.first { !$0.isEmpty } ?? ""
            it.password = rec["password"] ?? ""
            if let u = rec["url"] ?? rec["domain"] ?? rec["website"], !u.isEmpty { it.urls = [u] }
            it.otp = rec["otpurl"] ?? rec["otpsecret"] ?? rec["otp"] ?? ""
            for extra in ["username2", "username3"] {
                if let v = rec[extra], !v.isEmpty, v != it.username { it.fields.append(.init(label: "Other username", value: v)) }
            }
            if it.title.isEmpty { it.title = it.primaryHost.map(Domain.base) ?? it.username }
            guard !it.password.isEmpty || !it.username.isEmpty else { return nil }
        case .note:
            it.title = rec["title"] ?? "Note"
            guard !it.notes.isEmpty || !it.title.isEmpty else { return nil }
        default:
            let type = (rec["type"] ?? "").lowercased()
            if kind == .card, type.contains("bank") || (rec["account_number"]?.isEmpty == false && rec["cc_number"]?.isEmpty != false) {
                it.kind = .bank
            }
            it.title = [rec["title"], rec["item_name"], rec["account_name"], rec["name"], rec["issuing_bank"]].compactMap { $0 }.first { !$0.isEmpty }
                ?? (type.isEmpty ? it.kind.singular : type.capitalized)
            for (k, v) in rec.sorted(by: { $0.key < $1.key }) where !v.isEmpty {
                if ["title", "item_name", "note", "notes", "category", "type", "email_type"].contains(k) { continue }
                it.fields.append(.init(label: labels[k] ?? k.replacingOccurrences(of: "_", with: " ").capitalized, value: v, secret: secretKeys.contains(k)))
            }
            if !type.isEmpty { it.fields.insert(.init(label: "Type", value: type.capitalized), at: 0) }
            guard !it.fields.isEmpty else { return nil }
        }
        return it
    }

    // MARK: JSON (older Dashlane export)

    static func parseJSON(_ d: Data, into r: inout Result) throws {
        guard let obj = try? JSONSerialization.jsonObject(with: d) else { throw ImportError.unreadable }
        func strings(_ any: Any) -> [String: String] {
            guard let dict = any as? [String: Any] else { return [:] }
            var out = [String: String]()
            for (k, v) in dict {
                if let s = v as? String { out[k.lowercased()] = s } else if let n = v as? NSNumber { out[k.lowercased()] = n.stringValue }
            }
            return out
        }
        if let top = obj as? [String: Any] {
            for (section, value) in top {
                guard let list = value as? [Any] else { continue }
                let s = section.uppercased()
                let kind: ItemKind = s.contains("AUTH") || s.contains("CREDENTIAL") ? .login
                    : s.contains("NOTE") ? .note
                    : s.contains("CARD") || s.contains("PAYMENT") ? .card
                    : s.contains("BANK") ? .bank
                    : s.contains("ID") || s.contains("PASSPORT") || s.contains("LICENSE") ? .identity : .personal
                for e in list {
                    var rec = strings(e)
                    if rec["url"] == nil, let dom = rec["domain"] { rec["url"] = dom }
                    if rec["note"] == nil, let c = rec["content"] { rec["note"] = c }
                    if let item = makeItem(kind: kind, rec) { r.items.append(item) } else { r.skipped += 1 }
                }
            }
        } else if let list = obj as? [Any] {
            for e in list {
                let rec = strings(e)
                if let item = makeItem(kind: rec["password"] != nil ? .login : .note, rec) { r.items.append(item) } else { r.skipped += 1 }
            }
        }
    }
}

/// RFC 4180 CSV parser: quoted fields, doubled quotes, commas and newlines inside quotes.
enum CSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var it = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? { if let p = pending { pending = nil; return p }; return it.next() }
        var first = true
        while let c = next() {
            if first { first = false; if c == "\u{FEFF}" { continue } }
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case "\"" where field.isEmpty: inQuotes = true
                case ",": row.append(field); field = ""
                case "\r": continue
                case "\n": row.append(field); rows.append(row); row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// Minimal in-memory ZIP reader (stored and deflate entries) so the export never has to be
/// unpacked to disk.
enum Zip {
    static func entries(_ data: Data) throws -> [(String, Data)] {
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // Find end of central directory.
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 65_557) {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw DashlaneImport.ImportError.unreadable }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [(String, Data)] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(p) == 0x02014B50 else { throw DashlaneImport.ImportError.unreadable }
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24)
            let nlen = u16(p + 28), xlen = u16(p + 30), clen = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            p += 46 + nlen + xlen + clen
            guard !name.hasSuffix("/"), local + 30 <= b.count else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + csize <= b.count else { throw DashlaneImport.ImportError.unreadable }
            let comp = Data(b[start..<(start + csize)])
            switch method {
            case 0: out.append((name, comp))
            case 8: out.append((name, try inflate(comp, size: usize)))
            default: continue
            }
        }
        return out
    }

    static func inflate(_ src: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var dst = Data(count: size)
        let n = dst.withUnsafeMutableBytes { d in
            src.withUnsafeBytes { s in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, size,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw DashlaneImport.ImportError.unreadable }
        return dst
    }
}
