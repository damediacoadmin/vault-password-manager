import Foundation
import CryptoKit

/// End-to-end encrypted sync through Cloudflare. The server stores only the sealed vault and the
/// locked key envelope. The vault ID and the server password are derived from the vault key, so
/// only a device that has unlocked the vault can read or write it.
@MainActor
final class Sync: ObservableObject {
    /// Sync server, set at build time with VAULT_SYNC_URL (see local.yml). Ends with "/v/".
    static let base: URL = TestMode.isOn ? URL(string: "https://sync.invalid/v/")! : server
    /// The sync server itself. Test runs use it only through explicit test hooks, never for real syncing.
    static let server: URL = {
        let s = (Bundle.main.object(forInfoDictionaryKey: "VaultSyncURL") as? String) ?? ""
        return URL(string: s.isEmpty || s.hasPrefix("$(") ? "https://sync.invalid/v/" : s)!
    }()
    static var configured: Bool { base.host != "sync.invalid" }

    @Published var enabled = UserDefaults.standard.bool(forKey: "syncEnabled")
    @Published var status = "Off"
    @Published var lastSynced: Date?
    @Published var state: LinkState = .off
    enum LinkState { case off, syncing, synced, offline }
    private var pollTimer: Timer?

    static var deviceID: String {
        if let s = UserDefaults.standard.string(forKey: "syncDeviceID") { return s }
        let s = UUID().uuidString; UserDefaults.standard.set(s, forKey: "syncDeviceID"); return s
    }
    static var thisDevice: SyncedDevice {
        #if os(iOS)
        return SyncedDevice(id: deviceID, name: "iPhone", platform: "iPhone", lastSeen: Date())
        #else
        return SyncedDevice(id: deviceID, name: Host.current().localizedName ?? "Mac", platform: "Mac", lastSeen: Date())
        #endif
    }

    /// Other devices on this vault, seen in the last 30 days.
    var otherDevices: [SyncedDevice] {
        (store.payload.devices ?? []).filter { $0.id != Self.deviceID && $0.lastSeen > Date().addingTimeInterval(-30 * 86_400) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Short line for headers: "SYNCED 4:12 PM · 2 DEVICES".
    var summary: String {
        switch state {
        case .off: return "Sync off"
        case .syncing: return "Syncing"
        case .offline: return "Offline"
        case .synced:
            let n = otherDevices.count + 1
            return "Synced \((lastSynced ?? Date()).formatted(date: .omitted, time: .shortened)) · \(n) device\(n == 1 ? "" : "s")"
        }
    }

    /// Pulls every 30 seconds while the vault is open, so changes from the other device show up.
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.store.state == .unlocked else { return }
                await self.syncNow()
            }
        }
    }

    let store: VaultStore
    private var version = UserDefaults.standard.integer(forKey: "syncVersion")
    private var pushTask: Task<Void, Never>?
    private var busy = false

    init(store: VaultStore) {
        self.store = store
        store.onPersist = { [weak self] in self?.schedulePush() }
        if enabled { status = "On"; state = .syncing }
        startPolling()
    }

    // MARK: Identity

    static func vaultID(_ k: SymmetricKey) -> String {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: k, info: Data("vault-sync-id-v1".utf8), outputByteCount: 16)
            .withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }
    static func token(_ k: SymmetricKey) -> String {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: k, info: Data("vault-sync-auth-v1".utf8), outputByteCount: 32)
            .withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// Short code shown on the first device and typed on the next one: the vault ID in groups of 4.
    var syncCode: String? {
        guard let k = store.syncKey else { return nil }
        let id = Self.vaultID(k).uppercased()
        return stride(from: 0, to: id.count, by: 4).map { i in
            String(id[id.index(id.startIndex, offsetBy: i)..<id.index(id.startIndex, offsetBy: min(i + 4, id.count))])
        }.joined(separator: "-")
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "syncEnabled")
        status = on ? "On" : "Off"
        state = on ? .syncing : .off
        if on { Task { await syncNow() } }
    }

    // MARK: Sync

    func schedulePush() {
        guard enabled else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard enabled, !busy, let k = store.syncKey else { return }
        guard Self.configured else { status = "No sync server set in this build"; state = .offline; return }
        busy = true; defer { busy = false }
        status = "Syncing..."
        if state != .synced { state = .syncing }
        let id = Self.vaultID(k), tok = Self.token(k)
        do {
            // Pull and merge first.
            if let remote = try await Self.getRemote(id: id, token: tok) {
                version = remote.version
                let p = try VaultCrypto.openPayload(remote.payload, key: k)
                store.applyRemote(p)
            } else { version = 0 }
            store.touchDevice(Self.thisDevice)
            // Push the merged result.
            for _ in 0..<3 {
                let sealed = try VaultCrypto.sealPayload(store.payload, key: k)
                let env = try JSONEncoder.vault.encode(store.portableEnvelope())
                let r = try await put(id: id, token: tok, version: version, payload: sealed, envelope: env)
                if let v = r.newVersion { version = v; break }
                if let (v, remoteSealed) = r.conflict {
                    version = v
                    store.applyRemote(try VaultCrypto.openPayload(remoteSealed, key: k))
                }
            }
            UserDefaults.standard.set(version, forKey: "syncVersion")
            lastSynced = Date()
            status = "Up to date"
            state = .synced
        } catch {
            status = "Offline, will retry"
            state = .offline
        }
    }

    /// Joins a vault that already syncs from another device. Needs its sync code and master password.
    static func join(code: String, master: String, store: VaultStore, useBiometrics: Bool) async throws {
        let id = code.lowercased().filter { $0.isHexDigit }
        guard id.count == 32 else { throw JoinError.badCode }
        var req = URLRequest(url: base.appendingPathComponent(id).appendingPathComponent("envelope"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: String], let envB64 = obj["envelope"],
              let envData = Data(base64Encoded: envB64) else { throw JoinError.notFound }
        let env = try JSONDecoder.vault.decode(Envelope.self, from: envData)
        let k = try VaultCrypto.unwrap(env, master: master)
        guard vaultID(k) == id else { throw JoinError.badCode }
        guard let remote = try await getRemote(id: id, token: token(k)) else { throw JoinError.notFound }
        try store.adopt(envelope: env, key: k, payload: VaultCrypto.openPayload(remote.payload, key: k), useBiometrics: useBiometrics)
        UserDefaults.standard.set(true, forKey: "syncEnabled")
        UserDefaults.standard.set(remote.version, forKey: "syncVersion")
    }

    enum JoinError: LocalizedError {
        case badCode, notFound
        var errorDescription: String? {
            switch self {
            case .badCode: return "That sync code does not match. Check it on your other device."
            case .notFound: return "No synced vault found for that code."
            }
        }
    }

    // MARK: HTTP

    nonisolated static func getRemote(id: String, token: String) async throws -> (version: Int, payload: Data)? {
        var req = URLRequest(url: base.appendingPathComponent(id))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return nil }
        guard code == 200, let o = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = o["version"] as? Int, let p = (o["payload"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw URLError(.badServerResponse) }
        return (v, p)
    }

    private func put(id: String, token: String, version: Int, payload: Data, envelope: Data) async throws -> (newVersion: Int?, conflict: (Int, Data)?) {
        var req = URLRequest(url: Self.base.appendingPathComponent(id))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["version": version, "payload": payload.base64EncodedString(),
                                                                  "envelope": envelope.base64EncodedString()])
        let (d, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if code == 200, let v = o["version"] as? Int { return (v, nil) }
        if code == 409, let v = o["version"] as? Int, let p = (o["payload"] as? String).flatMap({ Data(base64Encoded: $0) }) { return (nil, (v, p)) }
        throw URLError(.badServerResponse)
    }

    // MARK: Merge

    /// Item-level merge: newest edit wins, deletions win over older edits.
    nonisolated static func merge(_ a: VaultPayload, _ b: VaultPayload) -> VaultPayload {
        var out = a
        var tomb = a.deleted ?? [:]
        for (k, v) in b.deleted ?? [:] { tomb[k] = max(tomb[k] ?? .distantPast, v) }
        var byID = [UUID: VaultItem]()
        for it in a.items + b.items {
            if let cur = byID[it.id], cur.modified >= it.modified { continue }
            byID[it.id] = it
        }
        out.items = byID.values.filter { it in (tomb[it.id.uuidString].map { $0 < it.modified } ?? true) }
            .sorted { $0.created < $1.created }
        out.deleted = tomb.isEmpty ? nil : tomb
        if (b.quickUsernamesChanged ?? .distantPast) > (a.quickUsernamesChanged ?? .distantPast) {
            out.quickUsernames = b.quickUsernames; out.quickUsernamesChanged = b.quickUsernamesChanged
        }
        var devs = [String: SyncedDevice]()
        for d in (a.devices ?? []) + (b.devices ?? []) { if let c = devs[d.id], c.lastSeen >= d.lastSeen { continue }; devs[d.id] = d }
        out.devices = devs.isEmpty ? nil : Array(devs.values)
        var logs = [UUID: AIEvent]()
        for e in a.aiLog + b.aiLog { logs[e.id] = e }
        out.aiLog = logs.values.sorted { $0.date > $1.date }.prefix(500).map { $0 }
        return out
    }
}
