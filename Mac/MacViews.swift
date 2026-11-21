import SwiftUI
import UniformTypeIdentifiers

struct MacRoot: View {
    @EnvironmentObject var store: VaultStore
    var body: some View {
        Group {
            switch store.state {
            case .empty: MacSetup()
            case .locked: MacUnlock()
            case .unlocked: MacMain()
            }
        }
        .background(Ink.bg)
    }
}

// MARK: Lock screens

struct MacUnlock: View {
    @EnvironmentObject var store: VaultStore
    @State private var master = ""
    @State private var error: String?
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Eyebrow("Vault"); Spacer(); Eyebrow("Locked") }
            Spacer()
            Text("Locked.").font(.plex(40, .semibold)).foregroundStyle(Ink.text)
            Text("Your logins, cards and notes are sealed on this Mac.").font(.plex(16)).foregroundStyle(Ink.mid).padding(.top, 8)
            if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red).padding(.top, 12) }
            Spacer()
            if store.hasBiometrics {
                Button { bio() } label: {
                    HStack { Text("Unlock with \(VaultCrypto.biometryName())"); Spacer(); Image(systemName: "touchid").font(.system(size: 20)) }.padding(.horizontal, 16)
                }
                .buttonStyle(InkButtonStyle(kind: .accentOutline, height: 52))
                .padding(.bottom, 10)
            }
            HStack(spacing: 8) {
                SecureField("", text: $master, prompt: Text("Master password").foregroundStyle(Ink.muted))
                    .textFieldStyle(.plain).font(.plex(15)).foregroundStyle(Ink.text).focused($focus)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                    .onSubmit(unlock)
                Button("Unlock", action: unlock).buttonStyle(InkButtonStyle(kind: .primary, height: 44)).frame(width: 110).disabled(master.isEmpty)
            }
            Hairline().padding(.top, 24)
            HStack { Eyebrow("AES-256"); Spacer(); Eyebrow("Secure Enclave"); Spacer(); Eyebrow("Locks on sleep") }.padding(.top, 10)
        }
        .padding(32)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focus = !store.hasBiometrics }
    }

    private func unlock() {
        let pw = master; master = ""
        do { try store.unlock(master: pw); error = nil } catch { self.error = error.localizedDescription }
    }
    private func bio() {
        do { try store.unlockWithBiometrics(); error = nil } catch VaultError.cancelled {} catch { self.error = error.localizedDescription }
    }
}

struct MacSetup: View {
    @EnvironmentObject var store: VaultStore
    @State private var master = ""
    @State private var confirm = ""
    @State private var useBio = true
    @State private var code: String?
    @State private var error: String?
    @State private var saved = false
    @State private var joining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let code {
                Eyebrow("Recovery kit")
                Text("Write this down.").font(.plex(32, .semibold)).foregroundStyle(Ink.text)
                Text("If you forget your master password, this code is the only way back in. Keep it on paper. Vault will not show it again.")
                    .font(.plex(15)).foregroundStyle(Ink.mid)
                Text(code).font(.mono(22, .medium)).tracking(3).foregroundStyle(Ink.amber).textSelection(.enabled)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.amberFill, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.amber))
                InkToggle(isOn: $saved, label: "I wrote it down")
                Button("Open my vault") { store.finishSetup() }.buttonStyle(InkButtonStyle(kind: .primary)).disabled(!saved).opacity(saved ? 1 : 0.5)
            } else {
                Eyebrow("Vault · new")
                Text("Create your vault.").font(.plex(32, .semibold)).foregroundStyle(Ink.text)
                Text("Pick a master password only you know. Five random words works well. Nobody can reset it for you.")
                    .font(.plex(15)).foregroundStyle(Ink.mid)
                MacField(label: "Master password", text: $master, secure: true)
                MacField(label: "Type it again", text: $confirm, secure: true)
                if !master.isEmpty { Eyebrow("\(PasswordGenerator.strength(master).rawValue) · \(Int(PasswordGenerator.entropy(master))) bits · 12 characters minimum") }
                if VaultCrypto.biometryAvailable { InkToggle(isOn: $useBio, label: "Unlock with Touch ID") }
                if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red) }
                Button("Create vault") {
                    do { code = try store.create(master: master, useBiometrics: useBio); master = ""; confirm = "" }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(InkButtonStyle(kind: .primary)).disabled(master.count < 12 || master != confirm)
                Button("Already use Vault on your iPhone? Join it") { joining = true }.buttonStyle(.plain).font(.plex(14)).foregroundStyle(Ink.amber)
            }
        }
        .padding(32).frame(maxWidth: 520).frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $joining) { JoinVaultView(sync: nil) { joining = false } }
    }
}

// MARK: Main window

enum MacSection: Hashable { case kind(ItemKind), health, claude, settings }

struct MacMain: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var sync: Sync
    @State private var section: MacSection = .kind(.login)
    @State private var selected: UUID?
    @State private var query = ""
    @State private var editing: VaultItem?
    @State private var isNew = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Rectangle().fill(Ink.line).frame(width: 1)
            switch section {
            case .kind(let k):
                list(k).frame(width: 320)
                Rectangle().fill(Ink.line).frame(width: 1)
                MacDetail(id: selected) { editing = $0; isNew = false }.frame(maxWidth: .infinity)
            case .health: MacHealth { selected = $0; section = .kind(.login) }
            case .claude: MacClaudeAccess()
            case .settings: MacSettings()
            }
        }
        .sheet(item: $editing) { item in MacEdit(item: item, isNew: isNew) { if let id = $0 { selected = id } } }
        .onAppear { inbox.fetchIfNeeded() }
        .onChange(of: inbox.token) { _, _ in inbox.fetchIfNeeded() }
        .alert("Transfer did not finish", isPresented: Binding(get: { inbox.error != nil }, set: { if !$0 { inbox.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(inbox.error ?? "") }
        .sheet(item: $inbox.result) { r in
            MacExchangeReview(result: r) { inbox.result = nil }
        }
    }
    @ObservedObject private var inbox = ExchangeInbox.shared

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Spacer().frame(height: 36)
            Eyebrow("Vault").padding(.horizontal, 16).padding(.bottom, 6)
            side(.kind(.login), "Logins", count(.login))
            side(.kind(.card), "Cards and banks", count(.card) + count(.bank))
            side(.kind(.identity), "IDs", count(.identity))
            side(.kind(.note), "Notes", count(.note))
            side(.kind(.personal), "Personal info", count(.personal))
            Eyebrow("Safety").padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
            side(.health, "Health", nil)
            side(.claude, "Claude access", nil)
            side(.settings, "Settings", nil)
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                SyncBadge(sync: sync)
                if sync.enabled {
                    ForEach(sync.otherDevices) { d in
                        Text("\(d.name) · \(d.lastSeen.formatted(.relative(presentation: .named)))").font(.mono(11)).foregroundStyle(Ink.muted).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 4)
            .onTapGesture { section = .settings }
            Button { store.lock() } label: { Text("LOCK").font(.mono(12, .medium)).tracking(1).foregroundStyle(Ink.amber).frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.plain).padding(12)
        }
        .background(Ink.bg)
    }

    private func count(_ k: ItemKind) -> Int { store.items.filter { $0.kind == k }.count }

    private func side(_ s: MacSection, _ title: String, _ n: Int?) -> some View {
        let on = section == s
        return Button { section = s; query = "" } label: {
            HStack {
                Text(title).font(.plex(13)).foregroundStyle(on ? Ink.amber : Ink.text)
                Spacer()
                if let n { Text("\(n)").font(.mono(12)).foregroundStyle(Ink.muted) }
            }
            .padding(.horizontal, 13).frame(height: 30)
            .background(on ? Ink.panel : .clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(Ink.amber).frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func list(_ k: ItemKind) -> some View {
        let items = store.items.filter { $0.kind == k || (k == .card && $0.kind == .bank) }
            .filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query) || $0.urls.joined().localizedCaseInsensitiveContains(query) }
            .sorted { a, b in a.favorite != b.favorite ? a.favorite : a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                MacSearch(text: $query)
                Button { editing = VaultItem(kind: k); isNew = true } label: {
                    Image(systemName: "plus").foregroundStyle(Ink.bg).frame(width: 36, height: 36).background(Ink.amber, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).help("New \(k.singular.lowercased())")
            }
            .padding(.horizontal, 14).padding(.top, 36).padding(.bottom, 10)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { it in
                        Button { selected = it.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 0) {
                                        Text(it.displayName).font(.plex(14, .medium)).foregroundStyle(Ink.text).lineLimit(1)
                                        if let h = it.hostHint { Text(" · \(h)").font(.mono(11)).foregroundStyle(Ink.muted).lineLimit(1) }
                                    }
                                    Text(it.kind == .login ? it.username : it.subtitle)
                                        .font(.plex(13)).foregroundStyle(Ink.mid).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if !it.otp.isEmpty { Tag(text: "2FA") }
                                Button { store.toggleFavorite(it.id) } label: {
                                    Image(systemName: it.favorite ? "star.fill" : "star").font(.system(size: 12))
                                        .foregroundStyle(it.favorite ? Ink.amber : Ink.muted).frame(width: 24, height: 24).contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless).help(it.favorite ? "Remove from Favorites" : "Add to Favorites")
                            }
                            .padding(.horizontal, 14).frame(height: 52)
                            .background(selected == it.id ? Ink.panelHi : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(it.favorite ? "Remove from Favorites" : "Add to Favorites") { store.toggleFavorite(it.id) }
                        }
                        Hairline()
                    }
                    if items.isEmpty {
                        Text(store.items.isEmpty ? "Nothing here yet. Use + or move everything from Dashlane in Settings." : "Nothing matches.")
                            .font(.plex(13)).foregroundStyle(Ink.mid).padding(16)
                    }
                }
            }
        }
        .background(Ink.bg)
    }
}

struct MacDetail: View {
    @EnvironmentObject var store: VaultStore
    let id: UUID?
    var edit: (VaultItem) -> Void
    @State private var reveal = false

    var body: some View {
        if let id, let item = store.items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName).font(.plex(30, .semibold)).foregroundStyle(Ink.text)
                            if let h = item.primaryHost { Text(h).font(.mono(13)).foregroundStyle(Ink.muted) }
                        }
                        Spacer()
                        Button { store.toggleFavorite(item.id) } label: {
                            Image(systemName: item.favorite ? "star.fill" : "star").foregroundStyle(Ink.amber).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.plain).help(item.favorite ? "Remove from Favorites" : "Add to Favorites")
                        CapsButton("Edit") { edit(item) }
                    }
                    if let t = TOTP(item.otp) { MacCode(totp: t) }
                    Panel {
                        VStack(spacing: 0) {
                            let rows = fields(item)
                            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Eyebrow(r.0)
                                        Text(r.2 && !reveal ? String(repeating: "•", count: 14) : r.1).font(.mono(14)).foregroundStyle(Ink.text).textSelection(.enabled)
                                    }
                                    Spacer()
                                    if r.2 { CapsButton(reveal ? "Hide" : "Show", color: Ink.mid) { reveal.toggle() } }
                                    CapsButton("Copy") { Clipboard.copy(r.1); if r.0 == "Password" { store.markUsed(item.id) } }
                                }
                                .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 8)
                                if i < rows.count - 1 { Hairline() }
                            }
                        }
                    }
                    if !item.notes.isEmpty {
                        Panel { VStack(alignment: .leading, spacing: 6) { Eyebrow("Notes"); Text(item.notes).font(.plex(14)).foregroundStyle(Ink.text).textSelection(.enabled) }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    }
                    if item.kind.aiEligible {
                        Panel {
                            InkToggle(isOn: Binding(get: { item.aiAllowed }, set: { v in var it = item; it.aiAllowed = v; store.upsert(it) }),
                                      label: "Claude may request this login", detail: "Touch ID on this Mac, every time")
                                .padding(.horizontal, 16).padding(.vertical, 10)
                        }
                    }
                }
                .padding(24)
            }
            .onChange(of: id) { _, _ in reveal = false }
        } else {
            VStack { Eyebrow("Select an item") }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fields(_ it: VaultItem) -> [(String, String, Bool)] {
        var rows: [(String, String, Bool)] = []
        if !it.username.isEmpty { rows.append(("Username", it.username, false)) }
        if !it.password.isEmpty { rows.append(("Password", it.password, true)) }
        for u in it.urls { rows.append(("Website", u, false)) }
        for f in it.fields { rows.append((f.label, f.value, f.secret)) }
        return rows
    }
}

struct MacCode: View {
    let totp: TOTP
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let code = totp.code(at: ctx.date), left = totp.secondsLeft(at: ctx.date)
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Eyebrow("One-time code"); Spacer(); Eyebrow("\(left) s") }
                    HStack(alignment: .firstTextBaseline) {
                        Text(TOTP.pretty(code)).font(.mono(36, .medium)).tracking(4).foregroundStyle(Ink.amber)
                        Spacer()
                        CapsButton("Copy") { Clipboard.copy(code) }
                    }
                    CodeTicks(left: left, period: totp.period)
                }
                .padding(16)
            }
        }
    }
}

struct MacEdit: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State var item: VaultItem
    let isNew: Bool
    var saved: (UUID?) -> Void
    @State private var password = ""
    @State private var url = ""

    init(item: VaultItem, isNew: Bool, saved: @escaping (UUID?) -> Void) {
        _item = State(initialValue: item); self.isNew = isNew; self.saved = saved
        _password = State(initialValue: item.password); _url = State(initialValue: item.urls.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(isNew ? "New \(item.kind.singular)" : "Edit")
            MacField(label: "Title", text: $item.title)
            if item.kind == .login {
                MacField(label: "Username or email", text: $item.username, mono: true)
                HStack(alignment: .bottom) {
                    MacField(label: "Password", text: $password, mono: true)
                    CapsButton("New") { password = PasswordGenerator.make(.init()) }
                }
                MacField(label: "Website", text: $url, mono: true)
                MacField(label: "2FA setup key", text: $item.otp, mono: true)
            } else if item.kind != .note {
                ForEach($item.fields) { $f in MacField(label: f.label, text: $f.value, mono: f.secret) }
                Button("Add field") { item.fields.append(.init(label: "Other", value: "")) }.buttonStyle(.plain).foregroundStyle(Ink.amber)
            }
            MacField(label: "Notes", text: $item.notes)
            HStack {
                if !isNew { Button("Delete") { store.delete(item.id); saved(nil); dismiss() }.buttonStyle(InkButtonStyle(kind: .destructive, height: 36)).frame(width: 100) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(InkButtonStyle(kind: .secondary, height: 36)).frame(width: 100).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(InkButtonStyle(kind: .primary, height: 36)).frame(width: 100).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .padding(24).frame(width: 460).background(Ink.bg)
        .onAppear {
            if item.fields.isEmpty {
                switch item.kind {
                case .card: item.fields = [.init(label: "Name on card", value: ""), .init(label: "Number", value: "", secret: true), .init(label: "Expires", value: ""), .init(label: "Security code", value: "", secret: true)]
                case .bank: item.fields = [.init(label: "Bank", value: ""), .init(label: "Routing number", value: "", secret: true), .init(label: "Account number", value: "", secret: true)]
                case .identity: item.fields = [.init(label: "Type", value: ""), .init(label: "Number", value: "", secret: true), .init(label: "Name", value: ""), .init(label: "Expires", value: "")]
                case .personal: item.fields = [.init(label: "Name", value: ""), .init(label: "Email", value: ""), .init(label: "Phone", value: ""), .init(label: "Address", value: "")]
                default: break
                }
            }
        }
    }

    private func save() {
        var it = item
        if it.kind == .login {
            it.setPassword(password)
            it.urls = url.isEmpty ? [] : [url]
            if it.title.isEmpty { it.title = Domain.host(from: url).map(Domain.base) ?? url }
        }
        it.fields = it.fields.filter { !$0.value.isEmpty }
        store.upsert(it); saved(it.id); dismiss()
    }
}

// MARK: Health, Claude access, Settings

struct MacHealth: View {
    @EnvironmentObject var store: VaultStore
    var open: (UUID) -> Void
    @State private var breached: Set<UUID> = []
    @State private var checking = false

    var body: some View {
        let r = HealthReport.build(store.items, breachedIDs: breached)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Eyebrow("Health"); Spacer(); Eyebrow(checking ? "Checking breaches..." : "") }
                HStack(alignment: .lastTextBaseline, spacing: 12) {
                    Text("\(r.score)").font(.mono(80, .medium)).tracking(-3).foregroundStyle(Ink.text)
                    Text(r.toFix == 0 ? "out of 100. Nothing to fix." : "out of 100. Fix \(r.toFix) to reach 100.").font(.plex(15)).foregroundStyle(Ink.mid)
                }
                .padding(.top, 16)
                ScoreBar(total: r.total, bad: r.toFix).padding(.top, 12)
                group("Found in a breach", r.breached)
                group("Reused", r.reused.flatMap { $0 })
                group("Weak", r.weak)
                group("Older than 2 years", r.old)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity)
        .task {
            checking = true
            breached = await BreachCheck.breachedIDs(store.items)
            checking = false
        }
    }

    private func group(_ title: String, _ items: [VaultItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Eyebrow(title); Spacer(); Text("\(items.count)").font(.mono(14, .medium)).foregroundStyle(items.isEmpty ? Ink.muted : Ink.amber) }
                .padding(.top, 24).padding(.bottom, 8)
            Hairline()
            ForEach(items) { it in
                Button { open(it.id) } label: {
                    HStack { Text(it.title).font(.plex(14)).foregroundStyle(Ink.text); Spacer(); Text(it.primaryHost ?? "").font(.mono(12)).foregroundStyle(Ink.muted) }
                        .frame(height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Hairline()
            }
        }
    }
}

/// Same 50-cell bar as the iPhone.
struct ScoreBar: View {
    let total: Int
    let bad: Int
    var body: some View {
        let n = 50
        let badCells = total == 0 ? 0 : max(bad > 0 ? 1 : 0, Int((Double(bad) / Double(total) * Double(n)).rounded()))
        HStack(spacing: 2) { ForEach(0..<n, id: \.self) { i in Rectangle().fill(i >= n - badCells ? Ink.amber : Ink.text).frame(height: 12) } }
    }
}

struct MacClaudeAccess: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var ai: AIBroker
    @State private var connected = MCPSetup.isInstalled

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claude access").font(.plex(24, .semibold)).foregroundStyle(Ink.text)
                    Spacer()
                    Eyebrow("\(ai.requestsThisHour) of \(AIBroker.hourlyLimit) requests this hour")
                }
                Text("Every request is listed. Nothing is shared without Touch ID. Cards, IDs and notes are never shared.")
                    .font(.plex(13)).foregroundStyle(Ink.mid)
                Panel { InkToggle(isOn: Binding(get: { ai.enabled }, set: { ai.setEnabled($0) }), label: "Allow Claude to ask for logins").padding(.horizontal, 16).padding(.vertical, 10) }
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connected ? "Connected to Claude Code" : "Not connected yet").font(.plex(14, .medium)).foregroundStyle(Ink.text)
                            Text("Adds Vault's get_login tool to Claude Code on this Mac.").font(.plex(12)).foregroundStyle(Ink.muted)
                        }
                        Spacer()
                        CapsButton(connected ? "Reconnect" : "Connect") { connected = MCPSetup.install() }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                ForEach(ai.activeGrants, id: \.host) { g in
                    HStack {
                        Text("\(g.host.uppercased())").font(.mono(13)) + Text(" open for \(g.minutesLeft) more minutes").font(.plex(13))
                        Spacer()
                        CapsButton("Revoke") { ai.revoke(g.host) }
                    }
                    .foregroundStyle(Ink.amber).padding(.leading, 14)
                    .background(Ink.amberFill, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.amberLine))
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow { Eyebrow("Time"); Eyebrow("Site"); Eyebrow("From"); Eyebrow("Result") }.padding(.vertical, 8)
                    ForEach(store.payload.aiLog.prefix(100)) { e in
                        Divider().overlay(Ink.line).gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.mono(12))
                            Text(e.site).font(.mono(12))
                            Text(e.client).font(.plex(12))
                            Text(e.resultText).font(.plex(12))
                                .foregroundStyle(e.result == .denied || e.result == .blocked || e.result == .rateLimited ? Ink.red : e.result == .allowedWindow ? Ink.amber : Ink.text)
                        }
                        .foregroundStyle(Ink.text).padding(.vertical, 9)
                    }
                }
                if store.payload.aiLog.isEmpty { Text("No requests yet.").font(.plex(13)).foregroundStyle(Ink.muted) }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity)
    }
}

struct MacSettings: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var sync: Sync
    @State private var importing = false
    @State private var result: DashlaneImport.Result?
    @State private var error: String?
    @State private var bio = false
    @State private var lockAfter = MacLock.seconds

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Settings").font(.plex(24, .semibold)).foregroundStyle(Ink.text)
                SyncPanel(sync: sync).padding(.top, 8)
                TransferTrace()
                Eyebrow("Move from Dashlane").padding(.top, 8)
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("In Dashlane on the web, open Settings, then Export data, then Export to CSV. Then choose the .zip here. It is read in memory on this Mac and never copied.")
                            .font(.plex(13)).foregroundStyle(Ink.mid)
                        Button("Choose Dashlane export") { importing = true }.buttonStyle(InkButtonStyle(kind: .accentOutline, height: 40)).frame(width: 240)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let result {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(result.items.count) items ready to move").font(.plex(18, .semibold)).foregroundStyle(Ink.text)
                            Text("Logins \(result.count(.login)) · one-time codes \(result.otpCount) · notes \(result.count(.note)) · cards and banks \(result.count(.card) + result.count(.bank)) · IDs and personal \(result.count(.identity) + result.count(.personal))")
                                .font(.mono(12)).foregroundStyle(Ink.muted)
                            HStack {
                                Button("Cancel") { self.result = nil }.buttonStyle(InkButtonStyle(kind: .secondary, height: 36)).frame(width: 110)
                                Button("Move \(result.items.count) items") { store.add(result.items); self.result = nil }
                                    .buttonStyle(InkButtonStyle(kind: .primary, height: 36)).frame(width: 180)
                            }
                            Text("Afterwards, move the export file to the Trash and empty it. It holds your passwords unprotected.")
                                .font(.plex(12)).foregroundStyle(Ink.amber)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Eyebrow("Security").padding(.top, 8)
                Panel {
                    VStack(spacing: 0) {
                        if VaultCrypto.biometryAvailable {
                            InkToggle(isOn: $bio, label: "Unlock with Touch ID").padding(.horizontal, 16).padding(.vertical, 10)
                            Hairline()
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Lock when the Mac is idle for").font(.plex(14)).foregroundStyle(Ink.text)
                                Text("Vault always locks when the Mac sleeps or the screen locks.").font(.plex(12)).foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            Picker("", selection: $lockAfter) {
                                Text("5 minutes").tag(300); Text("15 minutes").tag(900); Text("30 minutes").tag(1800)
                                Text("1 hour").tag(3600); Text("4 hours").tag(14400); Text("Never").tag(0)
                            }
                            .labelsHidden().frame(width: 140)
                        }
                        .padding(16)
                    }
                }
                Eyebrow("AutoFill").padding(.top, 8)
                Text("Open System Settings, then General, then AutoFill & Passwords, and turn on Vault.").font(.plex(13)).foregroundStyle(Ink.mid)
                if let error { Text(error).font(.plex(13)).foregroundStyle(Ink.red) }
            }
            .padding(32).frame(maxWidth: 640, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .onAppear { bio = store.hasBiometrics; lockAfter = MacLock.seconds }
        .onChange(of: lockAfter) { _, v in MacLock.seconds = v }
        .onChange(of: bio) { _, v in
            guard v != store.hasBiometrics else { return }
            do { try store.setBiometrics(v) } catch { self.error = error.localizedDescription; bio = store.hasBiometrics }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .commaSeparatedText, .json, .plainText]) { res in
            guard case .success(let url) = res else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do { result = try DashlaneImport.read(data: Data(contentsOf: url), filename: url.lastPathComponent); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Registers vault-mcp with Claude Code (user scope) by running `claude mcp add`.
enum MCPSetup {
    static var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/vault-mcp").path }
    static var isInstalled: Bool {
        guard let d = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")),
              let s = String(data: d, encoding: .utf8) else { return false }
        return s.contains("vault-mcp")
    }
    static func install() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "claude mcp remove -s user vault >/dev/null 2>&1; claude mcp add -s user vault -- '\(helperPath)'"]
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: Mac components

struct MacSearch: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
            TextField("", text: $text, prompt: Text("Search").foregroundStyle(Ink.muted)).textFieldStyle(.plain).font(.plex(14)).foregroundStyle(Ink.text)
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
    }
}

struct MacField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(label)
            Group { if secure { SecureField("", text: $text) } else { TextField("", text: $text) } }
                .textFieldStyle(.plain).font(mono ? .mono(14) : .plex(14)).foregroundStyle(Ink.text)
                .padding(.horizontal, 12).frame(height: 36)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
        }
    }
}


struct MacExchangeReview: View {
    @EnvironmentObject var store: VaultStore
    let result: DashlaneImport.Result
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Move from \(result.files.first ?? "Dashlane")")
            Text("\(result.items.count) items ready to move").font(.plex(24, .semibold)).foregroundStyle(Ink.text)
            Text("Read on this Mac only, straight from the other app through Apple's secure transfer. No file is saved.").font(.plex(14)).foregroundStyle(Ink.mid)
            Panel {
                VStack(spacing: 0) {
                    row("Logins", result.count(.login)); Hairline()
                    row("Passkeys", result.items.reduce(0) { $0 + ($1.passkeys?.count ?? 0) }); Hairline()
                    row("One-time codes, inside logins", result.otpCount); Hairline()
                    row("Secure notes", result.count(.note)); Hairline()
                    row("Cards and bank accounts", result.count(.card) + result.count(.bank)); Hairline()
                    row("IDs and personal info", result.count(.identity) + result.count(.personal))
                }
            }
            if !result.passkeySites.isEmpty {
                Text("\(result.passkeySites.count) passkeys could not move. Vault lists those sites so you can add a new passkey on each: \(result.passkeySites.joined(separator: ", ")).")
                    .font(.plex(13)).foregroundStyle(Ink.amber)
            }
            HStack {
                Spacer()
                Button("Cancel", action: done).buttonStyle(InkButtonStyle(kind: .secondary, height: 36)).frame(width: 110)
                Button("Move \(result.items.count) items") { store.add(result.items); done() }.buttonStyle(InkButtonStyle(kind: .primary, height: 36)).frame(width: 180)
            }
        }
        .padding(28).frame(width: 620).background(Ink.bg)
    }
    private func row(_ k: String, _ n: Int) -> some View {
        HStack { Text(k).font(.plex(14)).foregroundStyle(Ink.text); Spacer(); Text("\(n)").font(.mono(15, .medium)).foregroundStyle(Ink.text) }
            .padding(.horizontal, 16).frame(height: 42)
    }
}
