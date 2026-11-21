import Foundation
import AuthenticationServices

/// Tells the system which sites Vault has logins for, so iPhone and Mac can offer them in the
/// QuickType bar. Only the site and username are shared with the system, never a password.
enum CredentialIdentities {
    static func sync(_ items: [VaultItem]) {
        let store = ASCredentialIdentityStore.shared
        store.getState { state in
            guard state.isEnabled else { return }
            var identities: [any ASCredentialIdentity] = []
            for it in items where it.kind == .login {
                for pk in it.passkeys ?? [] {
                    identities.append(ASPasskeyCredentialIdentity(relyingPartyIdentifier: pk.rpID, userName: pk.userName,
                                                                  credentialID: pk.credentialID, userHandle: pk.userHandle,
                                                                  recordIdentifier: it.id.uuidString))
                }
                guard !it.password.isEmpty else { continue }
                // Register the exact host and the main domain, so sign-in pages on other
                // subdomains (accounts.google.com for google.com) still suggest the login.
                let hosts = Array(Set(it.urls.compactMap(Domain.host(from:)).flatMap { [$0, Domain.base($0)] }))
                for host in hosts {
                    let sid = ASCredentialServiceIdentifier(identifier: host, type: .domain)
                    let p = ASPasswordCredentialIdentity(serviceIdentifier: sid, user: it.username, recordIdentifier: it.id.uuidString)
                    if let used = it.lastUsed { p.rank = Int(used.timeIntervalSince1970 / 3600) }
                    identities.append(p)
                    if #available(iOS 18.0, macOS 15.0, *), !it.otp.isEmpty {
                        identities.append(ASOneTimeCodeCredentialIdentity(serviceIdentifier: sid, label: it.username.isEmpty ? it.title : it.username,
                                                                          recordIdentifier: it.id.uuidString))
                    }
                }
            }
            store.replaceCredentialIdentities(identities) { _, _ in }
        }
    }

    /// Moves a just-used login to the front of the QuickType bar on its site.
    static func bump(_ it: VaultItem) {
        let store = ASCredentialIdentityStore.shared
        let rank = Int(Date().timeIntervalSince1970 / 60)
        let hosts = Array(Set(it.urls.compactMap(Domain.host(from:)).flatMap { [$0, Domain.base($0)] }))
        let ids: [any ASCredentialIdentity] = hosts.map { h in
            let p = ASPasswordCredentialIdentity(serviceIdentifier: ASCredentialServiceIdentifier(identifier: h, type: .domain),
                                                 user: it.username, recordIdentifier: it.id.uuidString)
            p.rank = rank
            return p
        }
        store.getState { s in if s.isEnabled { store.saveCredentialIdentities(ids) { _, _ in } } }
    }

    static func clear() { ASCredentialIdentityStore.shared.removeAllCredentialIdentities { _, _ in } }
}
