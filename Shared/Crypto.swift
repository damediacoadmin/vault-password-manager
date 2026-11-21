import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication
import Security

/// How the random vault key is locked. Stored in the Keychain next to the sealed vault.
/// None of these fields is secret on its own: each wrap is AES-GCM ciphertext.
struct Envelope: Codable {
    var version = 1
    var salt: Data
    var iterations: Int
    var passwordWrap: Data          // vault key sealed with PBKDF2(master password)
    var recoveryWrap: Data          // vault key sealed with HKDF(recovery code)
    var bioKey: Data?               // Secure Enclave key handle (useless off this device)
    var bioEphemeral: Data?         // ephemeral public key for the ECDH wrap
    var bioWrap: Data?              // vault key sealed with ECDH(Secure Enclave key)
}

enum VaultError: LocalizedError {
    case wrongPassword, wrongRecoveryCode, noVault, corrupt, biometryUnavailable, cancelled, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return "That master password is not right."
        case .wrongRecoveryCode: return "That recovery code is not right."
        case .noVault: return "No vault on this device yet."
        case .corrupt: return "The vault could not be read."
        case .biometryUnavailable: return "Face ID or Touch ID is not set up for Vault."
        case .cancelled: return "Cancelled."
        case .keychain(let s): return "Keychain error \(s)."
        }
    }
}

enum VaultCrypto {
    static let defaultIterations = 650_000

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let ok = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "No secure randomness")
        return d
    }

    static func pbkdf2(_ password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let pw = Array(password.precomposedStringWithCanonicalMapping.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { s in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw.map { Int8(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &out, out.count)
        }
        defer { out.withUnsafeMutableBytes { memset_s($0.baseAddress, 32, 0, 32) } }
        return SymmetricKey(data: out)
    }

    static func recoveryKey(_ code: String, salt: Data) -> SymmetricKey {
        let normalized = code.uppercased().filter { $0.isLetter || $0.isNumber }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(normalized.utf8)),
                                      salt: salt, info: Data("vault-recovery-v1".utf8), outputByteCount: 32)
    }

    /// 30 characters from a 32-letter alphabet without look-alikes = 150 bits.
    static func newRecoveryCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        let bytes = randomBytes(30)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 30, by: 5).map { String(chars[$0..<$0 + 5]) }.joined(separator: "-")
    }

    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined!
    }

    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
    }

    // MARK: Envelope

    static func makeEnvelope(vaultKey: SymmetricKey, master: String, recoveryCode: String) throws -> Envelope {
        let salt = randomBytes(16)
        let raw = vaultKey.withUnsafeBytes { Data($0) }
        let pw = try seal(raw, key: pbkdf2(master, salt: salt, iterations: defaultIterations), context: "pw")
        let rc = try seal(raw, key: recoveryKey(recoveryCode, salt: salt), context: "rc")
        return Envelope(salt: salt, iterations: defaultIterations, passwordWrap: pw, recoveryWrap: rc)
    }

    static func unwrap(_ env: Envelope, master: String) throws -> SymmetricKey {
        do { return SymmetricKey(data: try open(env.passwordWrap, key: pbkdf2(master, salt: env.salt, iterations: env.iterations), context: "pw")) }
        catch { throw VaultError.wrongPassword }
    }

    static func unwrap(_ env: Envelope, recoveryCode: String) throws -> SymmetricKey {
        do { return SymmetricKey(data: try open(env.recoveryWrap, key: recoveryKey(recoveryCode, salt: env.salt), context: "rc")) }
        catch { throw VaultError.wrongRecoveryCode }
    }

    static func rewrapPassword(_ env: inout Envelope, vaultKey: SymmetricKey, master: String) throws {
        let raw = vaultKey.withUnsafeBytes { Data($0) }
        env.passwordWrap = try seal(raw, key: pbkdf2(master, salt: env.salt, iterations: env.iterations), context: "pw")
    }

    // MARK: Secure Enclave (Face ID / Touch ID)

    static var biometryAvailable: Bool {
        SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func biometryName() -> String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }

    /// Creates a Secure Enclave key that only works after a biometric check with the
    /// currently enrolled faces or fingers, and wraps the vault key to it.
    static func addBiometrics(_ env: inout Envelope, vaultKey: SymmetricKey) throws {
        guard biometryAvailable else { throw VaultError.biometryUnavailable }
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &err) else {
            throw VaultError.biometryUnavailable
        }
        let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let eph = P256.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: se.publicKey)
        let key = bioKey(shared, eph: eph.publicKey.rawRepresentation, se: se.publicKey.rawRepresentation)
        env.bioKey = se.dataRepresentation
        env.bioEphemeral = eph.publicKey.rawRepresentation
        env.bioWrap = try seal(vaultKey.withUnsafeBytes { Data($0) }, key: key, context: "bio")
    }

    static func removeBiometrics(_ env: inout Envelope) {
        env.bioKey = nil; env.bioEphemeral = nil; env.bioWrap = nil
    }

    /// Asks for Face ID / Touch ID (the Secure Enclave enforces it) and returns the vault key.
    static func unwrapWithBiometrics(_ env: Envelope, reason: String) throws -> SymmetricKey {
        guard let handle = env.bioKey, let ephRaw = env.bioEphemeral, let wrap = env.bioWrap, SecureEnclave.isAvailable else {
            throw VaultError.biometryUnavailable
        }
        let ctx = LAContext()
        ctx.localizedReason = reason
        ctx.localizedFallbackTitle = ""
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle, authenticationContext: ctx)
            let eph = try P256.KeyAgreement.PublicKey(rawRepresentation: ephRaw)
            let shared = try se.sharedSecretFromKeyAgreement(with: eph)
            let key = bioKey(shared, eph: ephRaw, se: se.publicKey.rawRepresentation)
            return SymmetricKey(data: try open(wrap, key: key, context: "bio"))
        } catch let e as VaultError {
            throw e
        } catch {
            throw VaultError.cancelled
        }
    }

    private static func bioKey(_ shared: SharedSecret, eph: Data, se: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("vault-bio-v1".utf8),
                                       sharedInfo: eph + se, outputByteCount: 32)
    }

    // MARK: Payload

    static func sealPayload(_ p: VaultPayload, key: SymmetricKey) throws -> Data {
        var json = try JSONEncoder.vault.encode(p)
        defer { json.resetBytes(in: 0..<json.count) }
        return try seal(json, key: key, context: "vault-v1")
    }

    static func openPayload(_ d: Data, key: SymmetricKey) throws -> VaultPayload {
        guard var json = try? open(d, key: key, context: "vault-v1") else { throw VaultError.corrupt }
        defer { json.resetBytes(in: 0..<json.count) }
        return try JSONDecoder.vault.decode(VaultPayload.self, from: json)
    }
}

extension JSONEncoder {
    static var vault: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }
}

extension JSONDecoder {
    static var vault: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }
}

/// Keychain storage for the envelope and the sealed vault. Both live in a Keychain access
/// group shared by the app and its AutoFill extension, readable only while the device is
/// unlocked, and never synced or backed up to another device.
enum VaultKeychain {
    static let service = "com.damediaco.vault"
    static var accessGroup: String? = {
        // Team-prefixed group from the entitlements; nil in unsigned test runs.
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty,
              !prefix.hasPrefix("$(") else { return nil }
        return "\(prefix)com.damediaco.vault.shared"
    }()

    private static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecUseDataProtectionKeychain as String: true]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    static func read(_ account: String) throws -> Data? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw VaultError.keychain(s) }
        return out as? Data
    }

    static func write(_ account: String, _ data: Data) throws {
        let q = base(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var s = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if s == errSecItemNotFound {
            var add = q
            attrs.forEach { add[$0.key] = $0.value }
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw VaultError.keychain(s) }
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
