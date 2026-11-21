import Foundation
import CryptoKit

/// Time-based one-time codes (RFC 6238), the 6-digit codes sites use for two-factor sign-in.
struct TOTP {
    enum Algorithm: String { case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512" }

    var secret: Data
    var digits = 6
    var period = 30
    var algorithm = Algorithm.sha1

    /// Accepts an otpauth:// URL or a bare base32 secret.
    init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.lowercased().hasPrefix("otpauth://"), let comps = URLComponents(string: s) {
            let q = Dictionary((comps.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            guard let sec = q["secret"], let data = TOTP.base32(sec) else { return nil }
            secret = data
            if let d = q["digits"].flatMap(Int.init), (6...8).contains(d) { digits = d }
            if let p = q["period"].flatMap(Int.init), p > 0 { period = p }
            if let a = q["algorithm"].flatMap({ Algorithm(rawValue: $0.uppercased()) }) { algorithm = a }
        } else {
            guard let data = TOTP.base32(s) else { return nil }
            secret = data
        }
        if secret.isEmpty { return nil }
    }

    func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970 / Double(period)).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8]
        switch algorithm {
        case .sha1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        case .sha256: mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case .sha512: mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let bin = (UInt32(mac[offset] & 0x7f) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        let n = String(bin % mod)
        return String(repeating: "0", count: digits - n.count) + n
    }

    func secondsLeft(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map = [Character: UInt8]()
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        var bits: UInt32 = 0, count = 0
        var out = Data()
        for c in s.uppercased() where c != "=" && c != " " && c != "-" {
            guard let v = map[c] else { return nil }
            bits = (bits << 5) | UInt32(v)
            count += 5
            if count >= 8 {
                out.append(UInt8((bits >> UInt32(count - 8)) & 0xff))
                count -= 8
            }
        }
        return out
    }

    /// "482913" -> "482 913"
    static func pretty(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
