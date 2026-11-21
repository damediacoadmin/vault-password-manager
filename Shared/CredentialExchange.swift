import Foundation
import AuthenticationServices
import CryptoKit

/// Receives logins, passkeys and codes from another password manager (Dashlane) through Apple's
/// Credential Exchange on iOS 26 and macOS 26. The data moves app to app on this device, never
/// through a file.
@available(iOS 26.0, macOS 26.0, *)
enum CredentialExchange {
    static func token(from activity: NSUserActivity) -> UUID? {
        guard activity.activityType == ASCredentialExchangeActivity else { return nil }
        if let u = activity.userInfo?[ASCredentialImportToken] as? UUID { return u }
        if let s = activity.userInfo?[ASCredentialImportToken] as? String { return UUID(uuidString: s) }
        return nil
    }

    static func fetch(token: UUID) async throws -> DashlaneImport.Result {
        let data = try await ASCredentialImportManager().importCredentials(token: token)
        var r = DashlaneImport.Result()
        r.files = [data.exporterDisplayName]
        for account in data.accounts {
            for item in account.items { convert(item, into: &r) }
        }
        return r
    }

    private static func convert(_ src: ASImportableItem, into r: inout DashlaneImport.Result) {
        var login = VaultItem(kind: .login, title: src.title)
        login.urls = src.scope?.urls.map(\.absoluteString) ?? []
        login.favorite = src.favorite
        login.collection = src.tags.first ?? ""
        if let c = src.created { login.created = c }
        var extra: [VaultItem] = []
        for cred in src.credentials {
            switch cred {
            case .basicAuthentication(let b):
                login.username = b.userName?.value ?? login.username
                login.password = b.password?.value ?? login.password
            case .totp(let t):
                let secret = base32(t.secret)
                let algo = "\(t.algorithm)".uppercased()
                login.otp = "otpauth://totp/\(src.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "code")?secret=\(secret)&digits=\(t.digits)&period=\(t.period)&algorithm=\(algo)"
            case .passkey(let p):
                guard let key = try? P256.Signing.PrivateKey(derRepresentation: p.key) else { r.passkeySites.append(p.relyingPartyIdentifier); continue }
                let pk = Passkey(credentialID: p.credentialID, rpID: p.relyingPartyIdentifier, userHandle: p.userHandle,
                                 userName: p.userName, privateKey: key.rawRepresentation)
                login.passkeys = (login.passkeys ?? []) + [pk]
                if login.username.isEmpty { login.username = p.userName }
                if login.urls.isEmpty { login.urls = [p.relyingPartyIdentifier] }
            case .note(let n):
                if login.username.isEmpty && login.password.isEmpty && login.passkeys == nil {
                    extra.append(VaultItem(kind: .note, title: src.title, notes: n.content.value))
                } else { login.notes = n.content.value }
            case .creditCard(let c):
                var it = VaultItem(kind: .card, title: src.title)
                it.fields = [field("Name on card", c.fullName), field("Number", c.number, secret: true),
                             field("Expires", c.expiryDate), field("Security code", c.verificationNumber, secret: true)].compactMap { $0 }
                extra.append(it)
            case .driversLicense(let d):
                var it = VaultItem(kind: .identity, title: src.title)
                it.fields = [VaultItem.Field(label: "Type", value: "Driver's license"), field("Name", d.fullName), field("Number", d.licenseNumber, secret: true),
                             field("Expires", d.expiryDate), field("State", d.territory)].compactMap { $0 }
                extra.append(it)
            case .passport(let p):
                var it = VaultItem(kind: .identity, title: src.title)
                it.fields = [VaultItem.Field(label: "Type", value: "Passport"), field("Name", p.fullName), field("Number", p.passportNumber, secret: true),
                             field("Expires", p.expiryDate), field("Country", p.issuingCountry)].compactMap { $0 }
                extra.append(it)
            case .identityDocument(let d):
                var it = VaultItem(kind: .identity, title: src.title)
                it.fields = [field("Name", d.fullName), field("Number", d.documentNumber ?? d.identificationNumber, secret: true),
                             field("Expires", d.expiryDate)].compactMap { $0 }
                extra.append(it)
            case .wifi(let w):
                var it = VaultItem(kind: .note, title: src.title)
                it.fields = [field("Network", w.ssid), field("Password", w.passphrase, secret: true)].compactMap { $0 }
                extra.append(it)
            case .customFields(let c):
                for f in c.fields { if let v = field(c.label ?? "Field", f) { login.fields.append(v) } }
            default:
                continue
            }
        }
        if !login.username.isEmpty || !login.password.isEmpty || login.passkeys != nil || !login.otp.isEmpty {
            if login.title.isEmpty { login.title = login.primaryHost.map(Domain.base) ?? "Login" }
            r.items.append(login)
        }
        r.items.append(contentsOf: extra)
    }

    private static func field(_ label: String, _ f: ASImportableEditableField?, secret: Bool = false) -> VaultItem.Field? {
        guard let v = f?.value, !v.isEmpty else { return nil }
        return VaultItem.Field(label: label, value: v, secret: secret)
    }

    private static func base32(_ d: Data) -> String {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer = 0, bits = 0
        for b in d { buffer = (buffer << 8) | Int(b); bits += 8; while bits >= 5 { out.append(a[(buffer >> (bits - 5)) & 31]); bits -= 5 } }
        if bits > 0 { out.append(a[(buffer << (5 - bits)) & 31]) }
        return out
    }
}
