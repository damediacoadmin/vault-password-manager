import Foundation
import AppKit
import SwiftUI
import CryptoKit
import LocalAuthentication

/// The bridge between the Vault Chrome extension and this Mac app.
///
/// Chrome starts the signed `vault-chrome` helper (native messaging); the helper relays each
/// message to this private socket. Only that helper may connect, and only when Google Chrome
/// started it. On top of that every browser must be paired once (matching code, a click and
/// Touch ID), and every request carries the pairing key, which Vault checks against a hash.
///
/// What a paired browser can do:
/// - see the names and usernames of logins saved for the site it is on (no passwords)
/// - fill a login for the site it is on while the vault is unlocked
/// - fill a login saved for a DIFFERENT site only after Touch ID (phishing guard)
/// - search logins by name (names and usernames only)
/// - save a new login, or update a password after you confirm on the page
/// - generate a password with your saved generator settings
/// There is no way to list, export or dump the vault through here.
@MainActor
final class BrowserBroker: ObservableObject {
    struct Pairing: Codable, Identifiable, Equatable {
        var id: String          // random client ID made by the extension
        var name: String        // "Chrome on Dave's MacBook"
        var keyHash: String     // SHA-256 of the pairing key, hex
        var added: Date
        var lastUsed: Date?
    }
    struct PairRequest: Identifiable { let id = UUID(); let name: String; let code: String }

    @Published private(set) var pairings: [Pairing] = []
    @Published var pairRequest: PairRequest?
    @Published var enabled = UserDefaults.standard.object(forKey: "browserEnabled") as? Bool ?? true

    let store: VaultStore
    private var server: SocketServer?
    private var panel: NSPanel?
    private var decide: ((Bool) -> Void)?

    static var socketPath: String { TestMode.supportDir.appendingPathComponent("browser.sock").path }
    static let hostName = "com.damediaco.vault"

    init(store: VaultStore) {
        self.store = store
        pairings = Self.loadPairings()
    }

    func start() {
        server = SocketServer(path: Self.socketPath, helper: PeerCheck.helperID("chrome")) { [weak self] req in
            guard let self else { return ["ok": false, "error": "Vault is not running."] }
            return await self.handle(req)
        }
        server?.start()
        NativeHost.install()
    }

    func stop() { server?.stop() }

    func setEnabled(_ on: Bool) { enabled = on; UserDefaults.standard.set(on, forKey: "browserEnabled") }

    func remove(_ id: String) {
        pairings.removeAll { $0.id == id }
        Self.savePairings(pairings)
    }

    // MARK: Requests

    private func handle(_ req: [String: String]) async -> [String: Any] {
        let cmd = req["cmd"] ?? ""
        guard req["chrome"] == "1" else { return fail("Vault only answers Google Chrome.") }
        guard enabled else { return fail("Chrome access is turned off in Vault on your Mac.", code: "disabled") }
        guard store.state != .empty else { return fail("Set up Vault on this Mac first.", code: "empty") }

        if cmd == "pair" { return await pair(req) }
        guard let client = req["client"], let key = req["key"], let index = pairings.firstIndex(where: { $0.id == client }),
              Self.constantTimeEqual(Self.hash(key), pairings[index].keyHash) else {
            return fail("This browser is not connected to Vault yet.", code: "unpaired")
        }
        if pairings[index].lastUsed.map({ $0.timeIntervalSinceNow < -3600 }) ?? true {
            pairings[index].lastUsed = Date(); Self.savePairings(pairings)
        }

        switch cmd {
        case "status": return ok(["state": stateName])
        case "generate": return ok(["password": generate(req)])
        case "unlock":
            if store.state != .unlocked {
                #if DEBUG
                if TestMode.isOn { try? store.unlock(master: "test-only-not-real-0"); return ok(["state": stateName]) }
                #endif
                NSApp.activate(ignoringOtherApps: true)
                do { try store.unlockWithBiometrics(reason: "unlock Vault for Chrome") } catch { return fail("Vault is still locked.", code: "locked") }
            }
            return ok(["state": stateName])
        case "lock": store.lock(); return ok(["state": stateName])
        default: break
        }

        guard store.state == .unlocked else { return fail("Vault is locked on your Mac.", code: "locked") }
        let url = req["url"] ?? ""

        switch cmd {
        case "logins":
            guard let host = Domain.host(from: url) else { return ok(["host": "", "logins": [], "usernames": store.usernameSuggestions()]) }
            let list = store.logins(for: host).sorted(by: Self.order)
            return ok(["host": host, "logins": list.map(summary), "usernames": store.usernameSuggestions()])

        case "search":
            let q = (req["q"] ?? "").lowercased().trimmingCharacters(in: .whitespaces)
            let items = store.items.filter { $0.kind == .login }
            let hits = q.isEmpty ? items.filter(\.favorite) : items.filter {
                $0.displayName.lowercased().contains(q) || $0.title.lowercased().contains(q)
                    || $0.username.lowercased().contains(q) || $0.urls.contains { $0.lowercased().contains(q) }
            }
            return ok(["logins": hits.sorted(by: Self.order).prefix(40).map(summary)])

        case "fill":
            guard let id = req["id"].flatMap(UUID.init), let item = store.items.first(where: { $0.id == id }) else {
                return fail("That login is gone.")
            }
            let sameSite = item.urls.contains { Domain.matches(saved: $0, requested: url) }
            if !sameSite {
                // Filling a login on a site it was not saved for is how phishing works. Ask first.
                let where_ = Domain.host(from: url) ?? "this page"
                let why = req["purpose"] == "copy" ? "copy your \(item.displayName) password" : "fill your \(item.displayName) login on \(where_)"
                do { try await confirmPresence(why) }
                catch { return fail("Touch ID was not confirmed.", code: "denied") }
            }
            store.markUsed(id)
            var out: [String: Any] = ["username": item.username, "password": item.password]
            if let t = TOTP(item.otp) { out["code"] = t.code(); out["seconds"] = t.secondsLeft() }
            return ok(out)

        case "code":
            guard let id = req["id"].flatMap(UUID.init), let item = store.items.first(where: { $0.id == id }), let t = TOTP(item.otp) else {
                return fail("No 2FA code saved for this login.")
            }
            return ok(["code": t.code(), "seconds": t.secondsLeft()])

        case "check":   // is this sign-in already saved?
            let user = req["username"] ?? "", pw = req["password"] ?? ""
            guard let host = Domain.host(from: url), !pw.isEmpty else { return ok(["status": "skip"]) }
            let same = store.logins(for: host).filter { $0.username.caseInsensitiveCompare(user) == .orderedSame || ($0.username.isEmpty && user.isEmpty) }
            if same.contains(where: { $0.password == pw }) { return ok(["status": "same"]) }
            if let existing = same.first { return ok(["status": "update", "id": existing.id.uuidString, "title": existing.displayName]) }
            return ok(["status": "new", "title": Self.siteName(host)])

        case "save":
            let user = req["username"] ?? "", pw = req["password"] ?? ""
            guard let host = Domain.host(from: url), !pw.isEmpty else { return fail("Nothing to save.") }
            if let id = req["id"].flatMap(UUID.init), var item = store.items.first(where: { $0.id == id }) {
                guard item.urls.contains(where: { Domain.matches(saved: $0, requested: host) }) else { return fail("That login belongs to another site.") }
                if item.password != pw {
                    item.history.insert(PasswordChange(password: item.password, changed: item.passwordChanged), at: 0)
                    item.password = pw
                    item.passwordChanged = Date()
                }
                store.upsert(item)
                return ok(["id": item.id.uuidString])
            }
            var item = VaultItem()
            item.title = String((req["title"] ?? "").trimmingCharacters(in: .whitespaces).prefix(80))
            if item.title.isEmpty { item.title = Self.siteName(host) }
            item.username = String(user.prefix(200))
            item.password = String(pw.prefix(500))
            item.urls = ["https://\(host)"]
            item.lastUsed = Date()
            store.upsert(item)
            return ok(["id": item.id.uuidString])

        default:
            return fail("Unknown request.")
        }
    }

    private var stateName: String { store.state == .unlocked ? "unlocked" : store.state == .locked ? "locked" : "empty" }

    private func summary(_ it: VaultItem) -> [String: Any] {
        ["id": it.id.uuidString, "title": it.displayName, "username": it.username, "host": it.primaryHost ?? "",
         "totp": TOTP(it.otp) != nil, "favorite": it.favorite]
    }

    private static func order(_ a: VaultItem, _ b: VaultItem) -> Bool {
        if a.favorite != b.favorite { return a.favorite }
        return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast)
    }

    private func generate(_ req: [String: String]) -> String {
        var o = PasswordGenerator.saved
        if let s = req["style"], let st = PasswordGenerator.Options.Style(rawValue: s) { o.style = st }
        if let l = req["length"].flatMap(Int.init) { o.length = min(64, max(8, l)) }
        if let w = req["words"].flatMap(Int.init) { o.wordCount = min(10, max(3, w)) }
        if let s = req["symbols"] { o.symbols = s == "1" }
        if let d = req["digits"] { o.digits = d == "1"; o.number = d == "1" }
        if req["remember"] == "1" { PasswordGenerator.saved = o }
        return PasswordGenerator.make(o)
    }

    static func siteName(_ host: String) -> String {
        let first = Domain.base(host).split(separator: ".").first.map(String.init) ?? host
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    // MARK: Pairing

    private func pair(_ req: [String: String]) async -> [String: Any] {
        guard let client = req["client"], client.count >= 16, client.count <= 64,
              let key = req["key"], key.count >= 32 else { return fail("Bad pairing request.") }
        let name = String((req["name"] ?? "Chrome").prefix(60))
        if let p = pairings.first(where: { $0.id == client }), Self.constantTimeEqual(Self.hash(key), p.keyHash) {
            return ok(["paired": true])
        }
        let code = Self.pairCode(client: client, key: key)
        #if DEBUG
        if TestMode.isOn {
            guard TestSeed.approve else { return fail("Connection was not approved on your Mac.", code: "denied") }
            pairings.append(Pairing(id: client, name: name, keyHash: Self.hash(key), added: Date(), lastUsed: Date()))
            Self.savePairings(pairings)
            return ok(["paired": true, "code": code])
        }
        #endif
        NSApp.activate(ignoringOtherApps: true)
        let yes = await ask(PairRequest(name: name, code: code))
        guard yes else { return fail("Connection was not approved on your Mac.", code: "denied") }
        do { try await confirmPresence("connect Chrome to Vault") } catch { return fail("Touch ID was not confirmed.", code: "denied") }
        pairings.removeAll { $0.id == client }
        pairings.append(Pairing(id: client, name: name, keyHash: Self.hash(key), added: Date(), lastUsed: Date()))
        Self.savePairings(pairings)
        return ok(["paired": true])
    }

    /// Six digits both sides show, so you can tell it is your own browser asking.
    static func pairCode(client: String, key: String) -> String {
        let d = Array(SHA256.hash(data: Data("vault-pair|\(client)|\(key)".utf8)))
        let n = (UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])) % 1_000_000
        let s = String(format: "%06u", n)
        return "\(s.prefix(3)) \(s.suffix(3))"
    }

    private func ask(_ p: PairRequest) async -> Bool {
        if decide != nil { return false }
        return await withCheckedContinuation { cont in
            pairRequest = p
            decide = { [weak self] r in
                cont.resume(returning: r)
                self?.decide = nil
                self?.pairRequest = nil
                self?.panel?.orderOut(nil)
            }
            showPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                if self?.pairRequest?.id == p.id { self?.decide?(false) }
            }
        }
    }

    func answer(_ yes: Bool) { decide?(yes) }

    private func showPanel() {
        let panel = self.panel ?? {
            let np = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                             styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            np.titlebarAppearsTransparent = true
            np.titleVisibility = .hidden
            np.isFloatingPanel = true
            np.level = .floating
            np.isMovableByWindowBackground = true
            np.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            np.backgroundColor = NSColor(Ink.bg)
            self.panel = np
            return np
        }()
        panel.contentView = NSHostingView(rootView: PairCard(broker: self).preferredColorScheme(.dark))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 360, y: screen.maxY - 320))
        }
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func confirmPresence(_ reason: String) async throws {
        #if DEBUG
        if TestMode.isOn { if TestSeed.approve { return } else { throw VaultError.cancelled } }
        #endif
        let ctx = LAContext()
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard try await ctx.evaluatePolicy(policy, localizedReason: reason) else { throw VaultError.cancelled }
    }

    // MARK: Helpers

    private func ok(_ body: [String: Any]) -> [String: Any] { var b = body; b["ok"] = true; return b }
    private func fail(_ msg: String, code: String = "error") -> [String: Any] { ["ok": false, "error": msg, "code": code] }

    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    private static func loadPairings() -> [Pairing] {
        (try? VaultKeychain.read("browserPairs")).flatMap { try? JSONDecoder().decode([Pairing].self, from: $0) } ?? []
    }
    private static func savePairings(_ p: [Pairing]) {
        if let d = try? JSONEncoder().encode(p) { try? VaultKeychain.write("browserPairs", d) }
    }
}

/// Tells Chrome where the Vault helper lives. Chrome reads this small file from its
/// NativeMessagingHosts folder and only lets the Vault extension start the helper.
enum NativeHost {
    static let extensionIDs = ["cmjgeknhijfgeipkkclkdnmblamegcpm"]

    static func install() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vault-chrome").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return }
        let manifest: [String: Any] = [
            "name": BrowserBroker.hostName,
            "description": "Vault password manager",
            "path": helper,
            "type": "stdio",
            "allowed_origins": extensionIDs.map { "chrome-extension://\($0)/" }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = TestMode.isOn ? ["Library/Application Support/Google/Chrome for Testing/NativeMessagingHosts"]
                                    : ["Library/Application Support/Google/Chrome/NativeMessagingHosts"]
        for f in folders {
            let dir = home.appendingPathComponent(f, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(BrowserBroker.hostName).json")
            if (try? Data(contentsOf: file)) != data { try? data.write(to: file, options: .atomic) }
        }
    }
}

struct PairCard: View {
    @ObservedObject var broker: BrowserBroker

    var body: some View {
        if let p = broker.pairRequest {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("Connect a browser", color: Ink.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(.plex(17, .semibold)).foregroundStyle(Ink.text)
                    Text("wants to fill and save logins").font(.plex(13)).foregroundStyle(Ink.muted)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.code).font(.mono(30, .medium)).tracking(4).foregroundStyle(Ink.amber)
                    Text("Only connect if Chrome shows this same code.").font(.plex(13)).foregroundStyle(Ink.mid)
                }
                VStack(spacing: 8) {
                    Button("Connect") { broker.answer(true) }.buttonStyle(InkButtonStyle(kind: .primary, height: 38))
                        .keyboardShortcut(.defaultAction)
                    Button("Don't connect") { broker.answer(false) }.buttonStyle(InkButtonStyle(kind: .destructive, height: 38))
                        .keyboardShortcut(.cancelAction)
                }
                Eyebrow("Touch ID confirms your choice")
            }
            .padding(18)
            .frame(width: 340)
            .background(Ink.bg)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.amber, lineWidth: 1))
        }
    }
}

struct MacChromeAccess: View {
    @EnvironmentObject var browser: BrowserBroker

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Chrome").font(.plex(24, .semibold)).foregroundStyle(Ink.text)
                Text("The Vault extension fills, saves and generates passwords in Google Chrome. Your logins stay in this app. Chrome only gets the one login you pick, and only while Vault is unlocked.")
                    .font(.plex(13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
                Panel { InkToggle(isOn: Binding(get: { browser.enabled }, set: { browser.setEnabled($0) }), label: "Allow the Chrome extension").padding(.horizontal, 16).padding(.vertical, 10) }
                Eyebrow("Connected browsers").padding(.top, 8)
                if browser.pairings.isEmpty {
                    Text("None yet. Click the Vault button in Chrome's toolbar to connect.").font(.plex(13)).foregroundStyle(Ink.muted)
                }
                ForEach(browser.pairings) { p in
                    Panel {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.name).font(.plex(14, .medium)).foregroundStyle(Ink.text)
                                Text("Connected \(p.added.formatted(date: .abbreviated, time: .omitted))" + (p.lastUsed.map { " · used \($0.formatted(.relative(presentation: .named)))" } ?? ""))
                                    .font(.mono(11)).foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            CapsButton("Disconnect", color: Ink.red) { browser.remove(p.id) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
                Eyebrow("How it stays safe").padding(.top, 8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(["Only Google Chrome, running the Vault extension, can reach this app.",
                             "Each browser is connected once, with a matching code and Touch ID.",
                             "Chrome sees names and usernames for the site you are on, never a list of passwords.",
                             "Filling a login on a different site than it was saved for needs Touch ID, so look-alike sites get nothing.",
                             "Disconnect a browser here at any time."], id: \.self) { t in
                        Text("· " + t).font(.plex(13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity)
    }
}
