#if DEBUG
import AppKit

/// Debug builds only, with VAULT_TEST_MODE=1: a throwaway vault (separate Keychain namespace)
/// with made-up logins, no windows or menu bar icon, for automated Chrome extension tests.
enum TestSeed {
    @MainActor static func run(_ store: VaultStore) {
        guard TestMode.isOn else { return }
        if ProcessInfo.processInfo.environment["VAULT_TEST_CLEANUP"] == "1" {
            store.eraseEverything()
            for k in ["browserPairs", "genOptions", "lockout", "afTrace"] { VaultKeychain.delete(k) }
            exit(0)
        }
        NSApp.setActivationPolicy(.prohibited)
        DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
        let env = ProcessInfo.processInfo.environment
        if let link = env["VAULT_TEST_LINK"] { act { try store.unlock(master: master); guard let r = ChromeLink.parse(link) else { throw VaultError.corrupt }
            try await ChromeLink.send(r, store: store, deviceName: "Test iPhone"); print("LINKED") }; return }
        if env["VAULT_TEST_PULL"] == "1" { act { try store.unlock(master: master); try await dump(store) }; return }
        store.eraseEverything()
        VaultKeychain.delete("browserPairs")
        _ = try? store.create(master: master, useBiometrics: false)
        store.finishSetup()
        store.add([
            VaultItem(title: "Example", username: "dave@example.com", password: "harbor-Tangle-7-velvet-Orbit", urls: ["https://login.example.test"], otp: "JBSWY3DPEHPK3PXP", lastUsed: Date()),
            VaultItem(title: "Example work", username: "work@example.com", password: "quartz-Ember-3-saddle-river", urls: ["example.test"], favorite: true),
            VaultItem(title: "Other site", username: "other@example.com", password: "orbit-Lamp-4-tide-Quill", urls: ["other.test"]),
            VaultItem(title: "Private bank", username: "bank@example.com", password: "never-Share-This-9", urls: ["bank.test"], aiAllowed: false),
        ])
        store.setQuickUsernames(["dave@example.com", "work@example.com"])
        if env["VAULT_TEST_SYNC"] == "1" { act { try await upload(store); print("UPLOADED \(Sync.vaultID(store.syncKey!))") }; return }
    }

    static let master = "test-only-not-real-0"

    /// Runs one async test step, prints any error, then quits.
    @MainActor static func act(_ f: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await f() } catch { print("ERROR \(error)") }
            fflush(stdout); exit(0)
        }
    }

    /// Puts the throwaway test vault on the sync server as a brand-new vault.
    @MainActor static func upload(_ store: VaultStore) async throws {
        let k = store.syncKey!
        var req = URLRequest(url: Sync.server.appendingPathComponent(Sync.vaultID(k)))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(Sync.token(k))", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let sealed = try VaultCrypto.sealPayload(store.payload, key: k)
        let env = try JSONEncoder.vault.encode(store.portableEnvelope())
        req.httpBody = try JSONSerialization.data(withJSONObject: ["version": 0, "payload": sealed.base64EncodedString(), "envelope": env.base64EncodedString()])
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw NSError(domain: String(decoding: d, as: UTF8.self), code: 1) }
    }

    /// Prints what the server copy holds (test vault only), to check what Chrome saved.
    @MainActor static func dump(_ store: VaultStore) async throws {
        let k = store.syncKey!
        var req = URLRequest(url: Sync.server.appendingPathComponent(Sync.vaultID(k)))
        req.setValue("Bearer \(Sync.token(k))", forHTTPHeaderField: "authorization")
        let (d, _) = try await URLSession.shared.data(for: req)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any], let b = o["payload"] as? String, let sealed = Data(base64Encoded: b) else { print("NONE"); return }
        print("VERSION \(o["version"] ?? "")")
        let p = try VaultCrypto.openPayload(sealed, key: k)
        for it in p.items { print("ITEM \(it.title) | \(it.username) | \(it.password) | \(it.history.count)") }
        for d in p.devices ?? [] { print("DEVICE \(d.name) \(d.platform)") }
    }

    /// Stand-in for the click and Touch ID during automated tests.
    static var approve: Bool { ProcessInfo.processInfo.environment["VAULT_TEST_APPROVE"] == "1" }
}
#endif
