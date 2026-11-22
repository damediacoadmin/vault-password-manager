import Foundation
import CryptoKit
import Combine

/// The single source of truth for an unlocked vault. Holds the vault key only while
/// unlocked; `lock()` drops the key and every decrypted item from memory.
@MainActor
final class VaultStore: ObservableObject {
    enum State: Equatable { case empty, locked, unlocked }

    @Published private(set) var state: State = .locked
    @Published private(set) var payload = VaultPayload()
    @Published var lastError: String?

    private var key: SymmetricKey?
    private var envelope: Envelope?
    var onChange: ((VaultPayload) -> Void)?

    init() { reloadState() }

    func reloadState() {
        if (try? VaultKeychain.read("envelope")) == nil { state = .empty } else if key == nil { state = .locked }
    }

    var items: [VaultItem] { payload.items }
    var hasBiometrics: Bool { (try? loadEnvelope())?.bioWrap != nil }

    // MARK: Setup and unlock

    /// Creates a brand new vault. Returns the recovery code to show the user once.
    func create(master: String, useBiometrics: Bool) throws -> String {
        let k = SymmetricKey(size: .bits256)
        let code = VaultCrypto.newRecoveryCode()
        var env = try VaultCrypto.makeEnvelope(vaultKey: k, master: master, recoveryCode: code)
        if useBiometrics, VaultCrypto.biometryAvailable { try VaultCrypto.addBiometrics(&env, vaultKey: k) }
        key = k
        envelope = env
        payload = VaultPayload()
        try VaultKeychain.write("envelope", JSONEncoder.vault.encode(env))
        try persist()
        return code   // state flips to .unlocked in finishSetup(), after the Recovery Kit is shown
    }

    func finishSetup() { if key != nil { state = .unlocked } }

    private func loadEnvelope() throws -> Envelope {
        if let e = envelope { return e }
        guard let d = try VaultKeychain.read("envelope") else { throw VaultError.noVault }
        let e = try JSONDecoder.vault.decode(Envelope.self, from: d)
        envelope = e
        return e
    }

    func unlock(master: String) throws {
        try Lockout.check()
        let env = try loadEnvelope()
        do { try finishUnlock(VaultCrypto.unwrap(env, master: master)); Lockout.reset() }
        catch VaultError.wrongPassword { Lockout.fail(); throw VaultError.wrongPassword }
    }

    func unlock(recoveryCode: String) throws {
        try Lockout.check()
        let env = try loadEnvelope()
        do { try finishUnlock(VaultCrypto.unwrap(env, recoveryCode: recoveryCode)); Lockout.reset() }
        catch VaultError.wrongRecoveryCode { Lockout.fail(); throw VaultError.wrongRecoveryCode }
    }

    func unlockWithBiometrics(reason: String = "Unlock your vault") throws {
        let env = try loadEnvelope()
        try finishUnlock(VaultCrypto.unwrapWithBiometrics(env, reason: reason))
    }

    private func finishUnlock(_ k: SymmetricKey) throws {
        guard let sealed = try VaultKeychain.read("vault") else { throw VaultError.noVault }
        payload = try VaultCrypto.openPayload(sealed, key: k)
        key = k
        state = .unlocked
    }

    func lock() {
        key = nil
        payload = VaultPayload()
        envelope = nil
        state = (try? VaultKeychain.read("envelope")) == nil ? .empty : .locked
    }

    // MARK: Settings

    func setBiometrics(_ on: Bool) throws {
        guard let k = key else { return }
        var env = try loadEnvelope()
        if on { try VaultCrypto.addBiometrics(&env, vaultKey: k) } else { VaultCrypto.removeBiometrics(&env) }
        envelope = env
        try VaultKeychain.write("envelope", JSONEncoder.vault.encode(env))
        objectWillChange.send()
    }

    func changeMaster(current: String, new: String) throws {
        var env = try loadEnvelope()
        let k = try VaultCrypto.unwrap(env, master: current)
        try VaultCrypto.rewrapPassword(&env, vaultKey: k, master: new)
        envelope = env
        try VaultKeychain.write("envelope", JSONEncoder.vault.encode(env))
    }

    func setAutoLock(_ seconds: Int) {
        UserDefaults.standard.set(seconds, forKey: "autoLockSeconds")
        mutate { $0.autoLockSeconds = seconds }
    }

    static var autoLockSeconds: Int { UserDefaults.standard.object(forKey: "autoLockSeconds") as? Int ?? 60 }
    func setAIEnabled(_ on: Bool) { mutate { $0.aiEnabled = on } }

    // MARK: Items

    func upsert(_ item: VaultItem) {
        mutate { p in
            var it = item
            it.modified = Date()
            if let i = p.items.firstIndex(where: { $0.id == item.id }) { p.items[i] = it } else { p.items.append(it) }
        }
    }

    func delete(_ id: UUID) {
        mutate { p in
            p.items.removeAll { $0.id == id }
            var d = p.deleted ?? [:]; d[id.uuidString] = Date(); p.deleted = d
        }
    }

    func setQuickUsernames(_ list: [String]) {
        mutate { $0.quickUsernames = list; $0.quickUsernamesChanged = Date() }
    }

    /// Your saved emails and usernames first, then the ones you use most.
    func usernameSuggestions(limit: Int = 8) -> [String] {
        var out = (payload.quickUsernames ?? []).filter { !$0.isEmpty }
        var count = [String: Int]()
        for it in payload.items where it.kind == .login && !it.username.isEmpty { count[it.username, default: 0] += 1 }
        for (u, _) in count.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) where !out.contains(u) {
            out.append(u)
        }
        return Array(out.prefix(limit))
    }

    func toggleFavorite(_ id: UUID) {
        mutate { p in if let i = p.items.firstIndex(where: { $0.id == id }) { p.items[i].favorite.toggle(); p.items[i].modified = Date() } }
    }

    func markUsed(_ id: UUID) {
        mutate { p in if let i = p.items.firstIndex(where: { $0.id == id }) { p.items[i].lastUsed = Date() } }
    }

    func add(_ new: [VaultItem]) { mutate { $0.items.append(contentsOf: new) } }

    func log(_ e: AIEvent) {
        mutate { p in
            if let i = p.aiLog.firstIndex(where: { $0.id == e.id }) { p.aiLog[i] = e } else { p.aiLog.insert(e, at: 0) }
            if p.aiLog.count > 500 { p.aiLog.removeLast(p.aiLog.count - 500) }
        }
    }

    /// Saves a new passkey on the login for that site, creating the login if needed.
    func addPasskey(_ pk: Passkey) {
        mutate { p in
            if let i = p.items.firstIndex(where: { $0.kind == .login && $0.urls.contains { Domain.matches(saved: $0, requested: pk.rpID) }
                                                     && ($0.username == pk.userName || $0.username.isEmpty) }) {
                p.items[i].passkeys = (p.items[i].passkeys ?? []) + [pk]
                if p.items[i].username.isEmpty { p.items[i].username = pk.userName }
                p.items[i].modified = Date()
            } else {
                var it = VaultItem(kind: .login, title: Domain.base(pk.rpID), username: pk.userName, urls: [pk.rpID])
                it.passkeys = [pk]
                p.items.append(it)
            }
        }
    }

    func passkeys(for rpID: String) -> [Passkey] {
        payload.items.flatMap { $0.passkeys ?? [] }.filter { $0.rpID.lowercased() == rpID.lowercased() }
    }

    func logins(for site: String) -> [VaultItem] {
        payload.items.filter { $0.kind == .login && $0.urls.contains { Domain.matches(saved: $0, requested: site) } }
    }

    // MARK: Sync hooks (see Sync.swift)

    var syncKey: SymmetricKey? { key }
    var onPersist: (() -> Void)?

    /// Envelope without this device's Face ID / Touch ID wrap, safe to store as ciphertext elsewhere.
    func portableEnvelope() throws -> Envelope {
        var e = try loadEnvelope()
        VaultCrypto.removeBiometrics(&e)
        return e
    }

    /// Replaces local state with a vault fetched from another device (already unlocked by the caller).
    func adopt(envelope remoteEnvelope: Envelope, key k: SymmetricKey, payload remote: VaultPayload, useBiometrics: Bool) throws {
        var env = remoteEnvelope
        if useBiometrics, VaultCrypto.biometryAvailable { try VaultCrypto.addBiometrics(&env, vaultKey: k) }
        let local = state == .unlocked ? payload : nil
        key = k; self.envelope = env
        payload = remote
        if let local { payload = Sync.merge(payload, local) }
        try VaultKeychain.write("envelope", JSONEncoder.vault.encode(env))
        try persist()
        state = .unlocked
        onChange?(payload)
    }

    /// Records this device as seen without triggering another sync.
    func touchDevice(_ d: SyncedDevice) {
        guard let k = key else { return }
        var list = payload.devices ?? []
        list.removeAll { $0.id == d.id }
        list.append(d)
        payload.devices = list
        try? VaultKeychain.write("vault", VaultCrypto.sealPayload(payload, key: k))
    }

    func applyRemote(_ remote: VaultPayload) {
        guard key != nil else { return }
        payload = Sync.merge(payload, remote)
        do { try VaultKeychain.write("vault", VaultCrypto.sealPayload(payload, key: key!)) } catch { lastError = error.localizedDescription }
        onChange?(payload)
    }

    private func mutate(_ f: (inout VaultPayload) -> Void) {
        guard key != nil else { return }
        f(&payload)
        do { try persist() } catch { lastError = error.localizedDescription }
        onChange?(payload)
        onPersist?()
    }

    private func persist() throws {
        guard let k = key else { return }
        try VaultKeychain.write("vault", VaultCrypto.sealPayload(payload, key: k))
    }

    /// Erases the vault from this device. Used only from Settings with confirmation.
    func eraseEverything() {
        VaultKeychain.delete("vault")
        VaultKeychain.delete("envelope")
        key = nil; envelope = nil; payload = VaultPayload(); state = .empty
    }
}

/// Slows down password guessing on this device: after 5 wrong tries, each further try must wait
/// 30 seconds, then 1, 5 and 15 minutes. Kept in the Keychain so reinstalling the app or clearing its
/// settings does not reset it.
enum Lockout {
    private struct State: Codable { var fails = 0; var until: Date = .distantPast }

    private static func load() -> State {
        (try? VaultKeychain.read("lockout")).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }
    private static func save(_ s: State) { if let d = try? JSONEncoder().encode(s) { try? VaultKeychain.write("lockout", d) } }

    static func check() throws {
        let s = load()
        let wait = s.until.timeIntervalSinceNow
        if wait > 0 { throw LockedOut(seconds: Int(wait.rounded(.up))) }
    }

    static func fail() {
        var s = load()
        s.fails += 1
        let delays: [Int: TimeInterval] = [5: 30, 6: 60, 7: 300]
        if s.fails >= 5 { s.until = Date().addingTimeInterval(delays[s.fails] ?? 900) }
        save(s)
    }

    static func reset() { VaultKeychain.delete("lockout") }

    struct LockedOut: LocalizedError {
        let seconds: Int
        var errorDescription: String? {
            seconds < 90 ? "Too many wrong tries. Wait \(seconds) seconds." : "Too many wrong tries. Wait \(seconds / 60 + 1) minutes."
        }
    }
}
