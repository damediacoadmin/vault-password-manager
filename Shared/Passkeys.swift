import Foundation
import CryptoKit

/// A passkey stored inside an encrypted vault item. The private key never leaves the vault.
struct Passkey: Codable, Hashable, Identifiable {
    var id: Data { credentialID }
    var credentialID: Data
    var rpID: String
    var userHandle: Data
    var userName: String
    var privateKey: Data        // P-256 raw representation
    var created: Date = Date()
}

/// WebAuthn "authenticator" maths for Vault's passkeys (ES256 only, attestation "none").
enum WebAuthn {
    static let es256 = -7

    // Flags: UP (user present) 0x01, UV (user verified) 0x04, BE (backup eligible) 0x08,
    // BS (backed up) 0x10, AT (attested credential data) 0x40.
    static let flagsAssert: UInt8 = 0x1D
    static let flagsCreate: UInt8 = 0x5D

    static func newPasskey(rpID: String, userName: String, userHandle: Data) -> Passkey {
        Passkey(credentialID: VaultCrypto.randomBytes(16), rpID: rpID, userHandle: userHandle, userName: userName,
                privateKey: P256.Signing.PrivateKey().rawRepresentation)
    }

    static func rpIDHash(_ rp: String) -> Data { Data(SHA256.hash(data: Data(rp.utf8))) }

    /// attestationObject for a new passkey.
    static func attestationObject(for pk: Passkey) throws -> Data {
        let key = try P256.Signing.PrivateKey(rawRepresentation: pk.privateKey)
        let raw = key.publicKey.rawRepresentation          // x || y, 32 bytes each
        let cose = CBOR.map([
            (.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
            (.int(-2), .bytes(raw.prefix(32))), (.int(-3), .bytes(raw.suffix(32)))
        ])
        var auth = rpIDHash(pk.rpID)
        auth.append(flagsCreate)
        auth.append(contentsOf: [0, 0, 0, 0])               // sign count: always 0 (synced passkey)
        auth.append(Data(count: 16))                         // AAGUID
        auth.append(contentsOf: [UInt8(pk.credentialID.count >> 8), UInt8(pk.credentialID.count & 0xff)])
        auth.append(pk.credentialID)
        auth.append(cose.encoded)
        return CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(auth))]).encoded
    }

    /// authenticatorData + DER signature for a sign-in.
    static func assert(_ pk: Passkey, clientDataHash: Data) throws -> (authData: Data, signature: Data) {
        var auth = rpIDHash(pk.rpID)
        auth.append(flagsAssert)
        auth.append(contentsOf: [0, 0, 0, 0])
        let key = try P256.Signing.PrivateKey(rawRepresentation: pk.privateKey)
        let sig = try key.signature(for: auth + clientDataHash).derRepresentation
        return (auth, sig)
    }
}

/// Tiny CBOR encoder: just what WebAuthn needs.
indirect enum CBOR {
    case int(Int), bytes(Data), text(String), map([(CBOR, CBOR)])

    var encoded: Data {
        switch self {
        case .int(let v): return v >= 0 ? CBOR.head(0, UInt64(v)) : CBOR.head(1, UInt64(-1 - v))
        case .bytes(let d): return CBOR.head(2, UInt64(d.count)) + d
        case .text(let s): let d = Data(s.utf8); return CBOR.head(3, UInt64(d.count)) + d
        case .map(let pairs):
            var out = CBOR.head(5, UInt64(pairs.count))
            for (k, v) in pairs { out += k.encoded; out += v.encoded }
            return out
        }
    }

    private static func head(_ major: UInt8, _ n: UInt64) -> Data {
        let m = major << 5
        switch n {
        case 0..<24: return Data([m | UInt8(n)])
        case 24..<256: return Data([m | 24, UInt8(n)])
        case 256..<65_536: return Data([m | 25, UInt8(n >> 8), UInt8(n & 0xff)])
        default: return Data([m | 26, UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        }
    }
}
