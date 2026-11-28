import Foundation
import AppKit
import SwiftUI
import LocalAuthentication
import Security

/// Lets an AI assistant ask for ONE login at a time. Requests arrive on a private Unix socket
/// from the signed `vault-mcp` helper only, and each one needs the owner's click plus Touch ID
/// (or the Mac password). There is no way to list or export the vault through here.
@MainActor
final class AIBroker: ObservableObject {
    struct Grant { let host: String; let until: Date; var minutesLeft: Int { max(0, Int(until.timeIntervalSinceNow / 60.0 + 0.99)) } }
    struct Pending: Identifiable { let id = UUID(); let client: String; let site: String; let reason: String; let item: VaultItem? ; let event: AIEvent }

    @Published private(set) var grants: [String: Date] = [:]
    @Published var pending: Pending?
    @Published var enabled = TestMode.isOn ? true : UserDefaults.standard.object(forKey: "aiEnabled") as? Bool ?? true

    let store: VaultStore
    private var server: SocketServer?
    private var panel: NSPanel?
    private var decide: ((AIEvent.Result) -> Void)?
    private var recent: [Date] = []

    static let hourlyLimit = 10
    static var socketPath: String {
        TestMode.supportDir.appendingPathComponent("ai.sock").path
    }

    init(store: VaultStore) { self.store = store }

    var activeGrants: [Grant] { grants.filter { $0.value > Date() }.map { Grant(host: $0.key, until: $0.value) }.sorted { $0.host < $1.host } }
    var requestsThisHour: Int { recent.filter { $0 > Date().addingTimeInterval(-3600) }.count }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !TestMode.isOn { UserDefaults.standard.set(on, forKey: "aiEnabled") }   // tests never change the real setting
        if !on { grants.removeAll() }
    }

    func revoke(_ host: String) { grants[host] = nil }

    func start() {
        server = SocketServer(path: Self.socketPath, helper: PeerCheck.helperID("mcp")) { [weak self] req in
            guard let self else { return ["ok": false, "error": "Vault is not running."] }
            return await self.handle(req)
        }
        server?.start()
    }

    func stop() { server?.stop() }

    // MARK: Requests

    private func handle(_ req: [String: String]) async -> [String: Any] {
        let site = (req["site"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = String((req["reason"] ?? "").prefix(200))
        let client = String((req["client"] ?? "AI assistant").prefix(60))
        var event = AIEvent(client: client, site: site, reason: reason, result: .waiting)

        func finish(_ r: AIEvent.Result, _ body: [String: Any]) -> [String: Any] {
            event.result = r
            if store.state == .unlocked { store.log(event) } else { pendingLog.append(event) }
            return body
        }

        guard store.state != .empty else { return ["ok": false, "error": "Vault is not set up on this Mac yet."] }
        guard enabled else { return finish(.blocked, ["ok": false, "error": "Claude access is turned off in Vault."]) }
        guard let host = Domain.host(from: site) else { return finish(.notFound, ["ok": false, "error": "Ask for a website, for example github.com."]) }
        recent.append(Date())
        guard requestsThisHour <= Self.hourlyLimit else {
            setEnabled(false)
            return finish(.rateLimited, ["ok": false, "error": "Too many requests this hour. Vault paused Claude access until the owner turns it back on."])
        }

        let wasLocked = store.state != .unlocked
        // A live 15-minute grant for this site skips the card but still needs the vault open.
        if let until = grants[Domain.base(host)], until > Date(), !wasLocked, let item = match(host) {
            return finish(.allowedWindow, credential(item))
        }

        let item = wasLocked ? nil : match(host)
        if !wasLocked, item == nil {
            let blocked = store.logins(for: host).contains { !$0.aiAllowed }
            return finish(blocked ? .blocked : .notFound, ["ok": false, "error": blocked ? "The owner set this login to never be shared with AI." : "No login saved for \(host)."])
        }

        let choice = await ask(Pending(client: client, site: host, reason: reason, item: item, event: event))
        guard choice == .allowedOnce || choice == .allowedWindow else {
            return finish(.denied, ["ok": false, "error": "The owner said no."])
        }
        // Touch ID (or the Mac password) proves the owner is at the keyboard.
        do {
            if wasLocked { try store.unlockWithBiometrics(reason: "share your \(host) login with \(client)") }
            else { try await confirmPresence("share your \(host) login with \(client)") }
        } catch {
            return finish(.denied, ["ok": false, "error": "Touch ID was not confirmed."])
        }
        flushPendingLog()
        guard let found = match(host) else {
            let r = finish(.notFound, ["ok": false, "error": "No login saved for \(host) that may be shared with AI."])
            if wasLocked { store.lock() }
            return r
        }
        if choice == .allowedWindow { grants[Domain.base(host)] = Date().addingTimeInterval(15 * 60) }
        let body = finish(choice, credential(found))
        if wasLocked { store.lock() }
        return body
    }

    private var pendingLog: [AIEvent] = []
    private func flushPendingLog() { for e in pendingLog.reversed() { store.log(e) }; pendingLog.removeAll() }

    private func match(_ host: String) -> VaultItem? {
        store.logins(for: host).filter { $0.aiAllowed && !$0.password.isEmpty }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }.first
    }

    private func credential(_ it: VaultItem) -> [String: Any] {
        var out: [String: Any] = ["ok": true, "site": it.primaryHost ?? "", "username": it.username, "password": it.password]
        if let t = TOTP(it.otp) { out["one_time_code"] = t.code() }
        return out
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

    // MARK: Approval card

    private func ask(_ p: Pending) async -> AIEvent.Result {
        #if DEBUG
        if TestMode.isOn {   // automated tests: the answer comes from VAULT_TEST_AI_ANSWER
            switch ProcessInfo.processInfo.environment["VAULT_TEST_AI_ANSWER"] {
            case "once": return .allowedOnce
            case "window": return .allowedWindow
            default: return .denied
            }
        }
        #endif
        if decide != nil { return .denied }   // one request at a time
        return await withCheckedContinuation { cont in
            pending = p
            decide = { [weak self] r in
                cont.resume(returning: r)
                self?.decide = nil
                self?.pending = nil
                self?.panel?.orderOut(nil)
            }
            showPanel(p)
            // Unanswered requests expire after 2 minutes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                if self?.pending?.id == p.id { self?.decide?(.denied) }
            }
        }
    }

    func answer(_ r: AIEvent.Result) { decide?(r) }

    private func showPanel(_ p: Pending) {
        let panel = self.panel ?? {
            let np = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 330),
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
        panel.contentView = NSHostingView(rootView: ApprovalCard(broker: self).environmentObject(store).preferredColorScheme(.dark))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 360, y: screen.maxY - 350))
        }
        panel.orderFrontRegardless()
        NSApp.requestUserAttention(.criticalRequest)
    }
}

struct ApprovalCard: View {
    @ObservedObject var broker: AIBroker
    @EnvironmentObject var store: VaultStore

    var body: some View {
        if let p = broker.pending {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("Request from \(p.client)", color: Ink.amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.item.map { "\($0.title) login" } ?? "Login for \(p.site)").font(.plex(17, .semibold)).foregroundStyle(Ink.text)
                    Text(p.item.map { "\($0.username) · \(p.site)" } ?? "\(p.site) · Vault is locked").font(.mono(13)).foregroundStyle(Ink.muted)
                }
                Text(p.reason.isEmpty ? "No reason given. Only this one login is sent." : "Reason given: \"\(p.reason)\" Only this one login is sent.")
                    .font(.plex(13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 8) {
                    Button("Allow once") { broker.answer(.allowedOnce) }.buttonStyle(InkButtonStyle(kind: .primary, height: 38))
                        .keyboardShortcut(.defaultAction)
                    Button("Allow for 15 minutes") { broker.answer(.allowedWindow) }.buttonStyle(InkButtonStyle(kind: .secondary, height: 38))
                    Button("Deny") { broker.answer(.denied) }.buttonStyle(InkButtonStyle(kind: .destructive, height: 38))
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

/// Minimal blocking Unix-socket server. One JSON object per line in, one per line out.
/// Only processes signed by this developer team as the Vault helper may connect.
final class SocketServer: @unchecked Sendable {
    let path: String
    let requirement: String
    let handler: ([String: String]) async -> [String: Any]
    private var fd: Int32 = -1
    private var running = false

    /// `helper` is the exact code-signing identifier allowed to connect, for example com.damediaco.vault.mcp.
    init(path: String, helper: String, handler: @escaping ([String: String]) async -> [String: Any]) {
        self.path = path
        self.requirement = PeerCheck.requirement(for: helper)
        self.handler = handler
    }

    func start() {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutableBytes(of: &addr.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(fd); return }
        chmod(path, 0o600)
        listen(fd, 4)
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() { running = false; if fd >= 0 { close(fd) }; unlink(path) }

    private func acceptLoop() {
        while running {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            Thread.detachNewThread { [weak self] in self?.serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var tv = timeval(tv_sec: 180, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard PeerCheck.isTrusted(c, requirement: requirement) else {
            write(c, ["ok": false, "error": "Only the signed Vault helper may connect."])
            return
        }
        var buf = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while !data.contains(0x0A) && data.count < 65536 {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let line = data.split(separator: 0x0A).first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return }
        let req = obj.compactMapValues { $0 as? String }
        let sem = DispatchSemaphore(value: 0)
        var reply: [String: Any] = [:]
        Task { reply = await handler(req); sem.signal() }
        sem.wait()
        write(c, reply)
    }

    private func write(_ c: Int32, _ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        d.append(0x0A)
        d.withUnsafeBytes { _ = Darwin.write(c, $0.baseAddress, d.count) }
        d.resetBytes(in: 0..<d.count)
    }
}

enum PeerCheck {
    /// This app's own Apple developer team, read from its signature.
    static let team: String = {
        var me: SecCode?
        var info: CFDictionary?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me {
            var st: SecStaticCode?
            if SecCodeCopyStaticCode(me, [], &st) == errSecSuccess, let st,
               SecCodeCopySigningInformation(st, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let t = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String { return t }
        }
        return "UNSIGNED"
    }()

    /// "mcp" -> com.damediaco.vault.mcp
    static func helperID(_ suffix: String) -> String {
        (Bundle.main.bundleIdentifier ?? "com.damediaco.vault.mac").replacingOccurrences(of: ".mac", with: "") + "." + suffix
    }

    /// Same Apple developer team as this app, and the helper's exact identifier.
    static func requirement(for identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
    }

    /// Verifies the connecting process's code signature using its audit token.
    static func isTrusted(_ fd: Int32, requirement: String) -> Bool {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return false }
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }
}
