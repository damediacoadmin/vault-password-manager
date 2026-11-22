import Foundation
import CryptoKit

/// Links the Vault Chrome extension to this vault by QR code.
///
/// Chrome shows `vault-link:<channel>.<public key>`. This device scans it, and after Face ID seals
/// the vault ID and vault key to that public key (ECDH P-256, HKDF-SHA256, AES-GCM) and drops the
/// sealed box on the sync server's one-time hand-off channel. Only the waiting browser holds the
/// matching private key, so the server never sees what is inside. Chrome then downloads the
/// already-encrypted vault from sync and opens it itself.
enum ChromeLink {
    struct Request: Equatable {
        let channel: String
        let browserKey: Data      // uncompressed P-256 point, 65 bytes
    }

    static let prefix = "vault-link:"

    static func parse(_ s: String) -> Request? {
        guard s.lowercased().hasPrefix(prefix) else { return nil }
        let rest = s.dropFirst(prefix.count).split(separator: ".", maxSplits: 1).map(String.init)
        guard rest.count == 2, rest[0].count == 32, rest[0].allSatisfy(\.isHexDigit),
              let key = Data(base64URL: rest[1]), key.count == 65,
              (try? P256.KeyAgreement.PublicKey(x963Representation: key)) != nil else { return nil }
        return Request(channel: rest[0].lowercased(), browserKey: key)
    }

    enum LinkError: LocalizedError {
        case syncOff, locked, server
        var errorDescription: String? {
            switch self {
            case .syncOff: return "Turn on Sync first, so Chrome can download your vault."
            case .locked: return "Unlock Vault first."
            case .server: return "Could not reach the sync server. Check your connection and try again."
            }
        }
    }

    @MainActor
    static func send(_ r: Request, store: VaultStore, deviceName: String) async throws {
        guard TestMode.isOn || (Sync.configured && UserDefaults.standard.bool(forKey: "syncEnabled")) else { throw LinkError.syncOff }
        guard let k = store.syncKey else { throw LinkError.locked }
        let body: [String: Any] = ["v": 1, "id": Sync.vaultID(k), "key": k.withUnsafeBytes { Data($0) }.base64EncodedString(), "from": deviceName]
        var json = try JSONSerialization.data(withJSONObject: body)
        defer { json.resetBytes(in: 0..<json.count) }
        let browser = try P256.KeyAgreement.PublicKey(x963Representation: r.browserKey)
        let mine = P256.KeyAgreement.PrivateKey()
        let shared = try mine.sharedSecretFromKeyAgreement(with: browser)
        let sym = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("vault-link-v1".utf8),
                                                 sharedInfo: Data(r.channel.utf8), outputByteCount: 32)
        let box = try AES.GCM.seal(json, using: sym, authenticating: Data("link".utf8)).combined!
        var req = URLRequest(url: Sync.server.deletingLastPathComponent().appendingPathComponent("link").appendingPathComponent(r.channel))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["pub": mine.publicKey.x963Representation.base64EncodedString(),
                                                                   "box": box.base64EncodedString()])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LinkError.server }
    }
}

extension Data {
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}
