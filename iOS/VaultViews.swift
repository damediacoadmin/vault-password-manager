import SwiftUI

struct MainTabs: View {
    @ObservedObject var inbox = ExchangeInbox.shared
    var body: some View {
        tabs
            .onAppear { inbox.fetchIfNeeded() }
            .onChange(of: inbox.token) { _, _ in inbox.fetchIfNeeded() }
            .alert("Transfer did not finish", isPresented: Binding(get: { inbox.error != nil }, set: { if !$0 { inbox.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(inbox.error ?? "") }
            .sheet(item: $inbox.result) { r in
                NavigationStack { ImportReview(result: r) { inbox.result = nil } }
            }
    }

    private var tabs: some View {
        TabView {
            VaultHome().tabItem { Label("VAULT", systemImage: "lock.shield") }
            HealthView().tabItem { Label("HEALTH", systemImage: "waveform.path.ecg") }
            GeneratorView().tabItem { Label("GENERATE", systemImage: "dice") }
            SettingsView().tabItem { Label("SETTINGS", systemImage: "slider.horizontal.3") }
        }
    }
}

/// One login, card or note in a list.
struct ItemRow: View {
    @EnvironmentObject var store: VaultStore
    let item: VaultItem
    /// Pass when known (the home list precomputes it); otherwise worked out here.
    var needsAttention: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Text(String(item.displayName.prefix(1)).uppercased())
                    .font(.mono(15, .medium)).foregroundStyle(Ink.text)
                    .frame(width: 36, height: 36)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                if attention {
                    Circle().fill(Ink.amber).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Ink.bg, lineWidth: 2)).offset(x: 3, y: -3)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(item.displayName).font(.plex(17, .medium)).foregroundStyle(Ink.text).lineLimit(1)
                    if let hint = item.hostHint { Text(" · \(hint)").font(.mono(12)).foregroundStyle(Ink.muted).lineLimit(1) }
                }
                if !secondLine.isEmpty {
                    Text(secondLine).font(.plex(15)).foregroundStyle(Ink.mid).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Button { store.toggleFavorite(item.id) } label: {
                Image(systemName: item.favorite ? "star.fill" : "star")
                    .font(.system(size: 17)).foregroundStyle(item.favorite ? Ink.amber : Ink.muted.opacity(0.7))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(item.favorite ? "Remove \(item.displayName) from Favorites" : "Add \(item.displayName) to Favorites")
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var secondLine: String {
        switch item.kind {
        case .login: return item.username
        case .card, .bank: return item.subtitle.replacingOccurrences(of: "Ending in ", with: "•••• ")
        default: return item.subtitle.isEmpty ? item.kind.singular : item.subtitle
        }
    }

    private var attention: Bool {
        if let needsAttention { return needsAttention }
        guard item.kind == .login, !item.password.isEmpty else { return false }
        return PasswordGenerator.strength(item.password) == .weak
            || store.items.contains { $0.id != item.id && $0.kind == .login && $0.password == item.password }
    }
}

struct VaultHome: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var sync: Sync
    @State private var query = ""
    @State private var filter: ItemKind?
    @State private var adding: VaultItem?
    @State private var path = NavigationPath()
    /// Favorites section updates a moment after the last star tap, so rows don't jump under your finger
    /// while you star several in a row.
    @State private var shownFavorites: [UUID] = []
    @State private var favTask: Task<Void, Never>?

    private var favoriteIDs: [UUID] { store.items.filter(\.favorite).map(\.id) }

    private var filtered: [VaultItem] {
        var list = store.items
        if let filter { list = list.filter { $0.kind == filter || (filter == .card && $0.kind == .bank) || (filter == .note && $0.kind == .personal) } }
        if !query.isEmpty {
            let q = query.lowercased()
            list = list.filter { $0.displayName.lowercased().contains(q) || $0.title.lowercased().contains(q) || $0.username.lowercased().contains(q) || $0.urls.joined().lowercased().contains(q) || $0.notes.lowercased().contains(q) }
        }
        return list.sorted { a, b in
            let c = a.displayName.localizedCaseInsensitiveCompare(b.displayName)
            return c == .orderedSame ? a.username < b.username : c == .orderedAscending
        }
    }

    private var recent: [VaultItem] {
        Array(store.items.filter { $0.lastUsed != nil }.sorted { $0.lastUsed! > $1.lastUsed! }.prefix(4))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Eyebrow("Vault / \(store.items.count)")
                        Spacer()
                        if sync.enabled { SyncBadge(sync: sync) } else { LockCountdown() }
                    }
                    HStack(spacing: 8) {
                        InkSearch(text: $query, prompt: "Search sites, names, notes")
                        addButton
                    }
                    counts
                    let report = HealthReport.build(store.items)
                    if report.toFix > 0 && query.isEmpty {
                        NavigationLink(value: Route.health) {
                            HStack {
                                Text("\(report.toFix) password\(report.toFix == 1 ? "" : "s") to fix: \(report.reusedCount) reused, \(report.weak.count) weak")
                                Spacer()
                                Text("→").font(.mono(15))
                            }
                            .font(.plex(14)).foregroundStyle(Ink.amber)
                            .padding(.horizontal, 14).frame(minHeight: 44)
                            .background(Ink.amberFill, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.amberLine))
                        }
                    }
                    let favs = shownFavorites.compactMap { id in store.items.first { $0.id == id } }
                        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                    if query.isEmpty && filter == nil && !favs.isEmpty {
                        section("Favorites", favs)
                    }
                    if query.isEmpty && filter == nil && !recent.isEmpty {
                        section("Recent", recent)
                    }
                    let list = filtered
                    let flagged = attentionIDs
                    if query.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                            ForEach(groups(list), id: \.0) { letter, items in
                                Eyebrow(letter).padding(.top, 18).padding(.bottom, 6)
                                Hairline()
                                ForEach(items) { row($0, flagged.contains($0.id)) }
                            }
                        }
                    } else {
                        section("Results", list)
                    }
                    if store.items.isEmpty {
                        Text("Nothing here yet. Tap + to add a login, or move everything from Dashlane in Settings.")
                            .font(.plex(15)).foregroundStyle(Ink.mid).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear { shownFavorites = favoriteIDs }
            .onChange(of: favoriteIDs) { _, ids in
                favTask?.cancel()
                favTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { shownFavorites = ids }
                }
            }
            .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { ItemDetailView(id: $0) }
            .navigationDestination(for: Route.self) { _ in HealthView(embedded: true) }
            .sheet(item: $adding) { item in NavigationStack { ItemEditView(item: item, isNew: true) } }
        }
    }

    enum Route: Hashable { case health }

    private var counts: some View {
        let c: [(ItemKind?, String, Int)] = [
            (.login, "Logins", store.items.filter { $0.kind == .login }.count),
            (.card, "Cards", store.items.filter { $0.kind == .card || $0.kind == .bank }.count),
            (.identity, "IDs", store.items.filter { $0.kind == .identity }.count),
            (.note, "Notes", store.items.filter { $0.kind == .note || $0.kind == .personal }.count)
        ]
        return HStack(spacing: 0) {
            ForEach(Array(c.enumerated()), id: \.offset) { i, e in
                let on = filter == e.0
                Button { filter = on ? nil : e.0 } label: {
                    VStack(spacing: 2) {
                        Text("\(e.2)").font(.mono(17, .medium)).foregroundStyle(Ink.text)
                        Text(e.1).font(.plex(12, .medium)).foregroundStyle(on ? Ink.text : Ink.mid)
                    }
                    .frame(maxWidth: .infinity).frame(height: 56)
                    .background(on ? Ink.panelHi : .clear)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if i < c.count - 1 { Rectangle().fill(Ink.line).frame(width: 1) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
    }

    private func section(_ title: String, _ items: [VaultItem]) -> some View {
        let flagged = attentionIDs
        return VStack(alignment: .leading, spacing: 0) {
            Eyebrow(title).padding(.top, 12).padding(.bottom, 8)
            Hairline()
            ForEach(items) { row($0, flagged.contains($0.id)) }
        }
    }

    private func row(_ item: VaultItem, _ flagged: Bool) -> some View {
        VStack(spacing: 0) {
            NavigationLink(value: item.id) { ItemRow(item: item, needsAttention: flagged) }.buttonStyle(.plain)
                .contextMenu {
                    Button { store.toggleFavorite(item.id) } label: {
                        Label(item.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.favorite ? "star.slash" : "star")
                    }
                }
            Rectangle().fill(Ink.panelHi).frame(height: 1)
        }
    }

    /// Logins that are reused or weak, worked out once per render instead of per row.
    private var attentionIDs: Set<UUID> {
        let logins = store.items.filter { $0.kind == .login && !$0.password.isEmpty }
        var count = [String: Int]()
        for l in logins { count[l.password, default: 0] += 1 }
        return Set(logins.filter { count[$0.password, default: 0] > 1 || PasswordGenerator.strength($0.password) == .weak }.map(\.id))
    }

    private func groups(_ items: [VaultItem]) -> [(String, [VaultItem])] {
        var order: [String] = []
        var map: [String: [VaultItem]] = [:]
        for it in items {
            let ch = it.displayName.first.map { $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
            if map[ch] == nil { order.append(ch) }
            map[ch, default: []].append(it)
        }
        return order.map { ($0, map[$0]!) }
    }

    private var addButton: some View {
        Menu {
            ForEach(ItemKind.allCases) { k in
                Button { adding = VaultItem(kind: k) } label: { Label(k.singular, systemImage: k.symbol) }
            }
            Button { adding = VaultItem(kind: .login, title: "", otp: "scan") } label: { Label("Scan a 2FA QR code", systemImage: "qrcode.viewfinder") }
        } label: {
            Image(systemName: "plus").font(.system(size: 20, weight: .medium)).foregroundStyle(Ink.bg)
                .frame(width: 48, height: 48).background(Ink.amber, in: RoundedRectangle(cornerRadius: 6))
        }
        .accessibilityLabel("Add item")
    }
}

/// "LOCKS IN 0:52" while the app is open, counting the auto-lock window.
struct LockCountdown: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Ink.amber).frame(width: 6, height: 6)
            Eyebrow("Unlocked")
        }
    }
}

struct ItemDetailView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var reveal = false
    @State private var editing = false
    @State private var showHistory = false

    private var item: VaultItem? { store.items.first { $0.id == id } }

    var body: some View {
        Group {
            if let item { content(item) } else { Color.clear }
        }
        // Once the login is deleted, go straight back to the list.
        .onChange(of: item == nil) { _, gone in if gone { dismiss() } }
        .onAppear { if item == nil { dismiss() } }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let item {
                    Button { store.toggleFavorite(item.id) } label: {
                        Image(systemName: item.favorite ? "star.fill" : "star").foregroundStyle(Ink.amber)
                    }
                    .accessibilityLabel(item.favorite ? "Remove from Favorites" : "Add to Favorites")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { CapsButton("Edit") { editing = true } }
        }
        .onDisappear { reveal = false }
    }

    @ViewBuilder
    private func content(_ item: VaultItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName).font(.plex(34, .semibold, relativeTo: .largeTitle)).foregroundStyle(Ink.text)
                    if item.kind == .login && !item.username.isEmpty { Text(item.username).font(.plex(17)).foregroundStyle(Ink.mid) }
                    if let h = item.primaryHost { Text(h).font(.mono(14)).foregroundStyle(Ink.muted) }
                    else if !item.collection.isEmpty { Text(item.collection).font(.mono(14)).foregroundStyle(Ink.muted) }
                }
                .padding(.bottom, 8)
                if let totp = TOTP(item.otp) { CodePanel(totp: totp) }
                fieldsPanel(item)
                if item.kind == .login && !item.password.isEmpty { statsPanel(item) }
                if !item.notes.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow("Notes")
                            Text(item.notes).font(.plex(15)).foregroundStyle(Ink.text).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                }
                if item.kind.aiEligible {
                    Panel {
                        InkToggle(isOn: Binding(get: { item.aiAllowed }, set: { v in var it = item; it.aiAllowed = v; store.upsert(it) }),
                                  label: "Claude may request this login", detail: "Touch ID on your Mac, every time")
                            .padding(.horizontal, 16).padding(.vertical, 12)
                    }
                }
                if !item.history.isEmpty {
                    Button { showHistory = true } label: {
                        HStack { Text("Password history").font(.plex(16)); Spacer(); Text("\(item.history.count)").font(.mono(15)).foregroundStyle(Ink.muted) }
                            .foregroundStyle(Ink.text).padding(.horizontal, 16).frame(minHeight: 52)
                    }
                    .buttonStyle(.plain)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                }
            }
            .padding(16)
        }
        .sheet(isPresented: $editing) { NavigationStack { ItemEditView(item: item, isNew: false) } }
        .sheet(isPresented: $showHistory) { NavigationStack { HistoryView(item: item) } }
    }

    private func fieldsPanel(_ item: VaultItem) -> some View {
        var rows: [(String, String, Bool)] = []
        if !item.username.isEmpty { rows.append(("Username", item.username, false)) }
        if !item.password.isEmpty { rows.append(("Password", item.password, true)) }
        for u in item.urls { rows.append(("Website", u, false)) }
        for f in item.fields { rows.append((f.label, f.value, f.secret)) }
        return Panel {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            Eyebrow(r.0)
                            Text(r.2 && !reveal ? String(repeating: "•", count: 14) : r.1)
                                .font(.mono(16)).tracking(r.2 && !reveal ? 2 : 0).foregroundStyle(Ink.text).textSelection(.enabled)
                        }
                        Spacer()
                        if r.2 { CapsButton(reveal ? "Hide" : "Show", color: Ink.mid) { reveal.toggle() } }
                        CapsButton("Copy") {
                            Clipboard.copy(r.1)
                            if r.0 == "Password" { store.markUsed(item.id) }
                        }
                        .accessibilityLabel("Copy \(r.0.lowercased())")
                    }
                    .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 10)
                    if i < rows.count - 1 { Hairline() }
                }
            }
        }
    }

    private func statsPanel(_ item: VaultItem) -> some View {
        let s = PasswordGenerator.strength(item.password)
        let bits = Int(PasswordGenerator.entropy(item.password))
        let uses = store.items.filter { $0.kind == .login && $0.password == item.password }.count
        let cells: [(String, String, Bool)] = [
            (s.rawValue.uppercased(), "\(bits) BITS", s == .weak),
            (uses > 1 ? "REUSED" : "UNIQUE", "\(uses) SITE\(uses == 1 ? "" : "S")", uses > 1),
            (item.passwordChanged < Date().addingTimeInterval(-2 * 365 * 86_400) ? "OLD" : "FRESH",
             item.passwordChanged.formatted(.dateTime.month(.abbreviated).year()).uppercased(), false)
        ]
        return HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                VStack(spacing: 2) {
                    Text(c.0).font(.mono(13, .medium)).foregroundStyle(c.2 ? Ink.amber : Ink.text)
                    Text(c.1).font(.mono(11, .medium)).tracking(1).foregroundStyle(Ink.muted)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                if i < cells.count - 1 { Rectangle().fill(Ink.line).frame(width: 1) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
        .accessibilityElement(children: .combine)
    }
}

struct CodePanel: View {
    let totp: TOTP
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let code = totp.code(at: ctx.date)
            let left = totp.secondsLeft(at: ctx.date)
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Eyebrow("One-time code"); Spacer(); Eyebrow("\(left) s") }
                    HStack(alignment: .firstTextBaseline) {
                        Text(TOTP.pretty(code)).font(.mono(44, .medium)).tracking(4).foregroundStyle(Ink.amber)
                            .minimumScaleFactor(0.6).lineLimit(1)
                        Spacer()
                        CapsButton("Copy") { Clipboard.copy(code) }.accessibilityLabel("Copy code")
                    }
                    CodeTicks(left: left, period: totp.period)
                }
                .padding(16)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("One-time code \(code), \(left) seconds left")
        }
    }
}

struct HistoryView: View {
    let item: VaultItem
    @Environment(\.dismiss) var dismiss
    @State private var reveal: Set<Int> = []
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(item.history.enumerated()), id: \.offset) { i, h in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reveal.contains(i) ? h.password : "••••••••••").font(.mono(16)).foregroundStyle(Ink.text)
                            Eyebrow("Used until \(h.changed.formatted(date: .abbreviated, time: .omitted))")
                        }
                        Spacer()
                        CapsButton(reveal.contains(i) ? "Hide" : "Show", color: Ink.mid) { if reveal.contains(i) { reveal.remove(i) } else { reveal.insert(i) } }
                    }
                    .padding(.vertical, 12)
                    Hairline()
                }
            }
            .padding(16)
        }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
        .navigationTitle("PASSWORD HISTORY")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { CapsButton("Done") { dismiss() } }
    }
}

struct ItemEditView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State var item: VaultItem
    let isNew: Bool
    @State private var newPassword = ""
    @State private var url = ""
    @State private var confirmDelete = false
    @State private var scanning = false
    @State private var genOptions = PasswordGenerator.saved
    @State private var showGen = false

    init(item: VaultItem, isNew: Bool) {
        var it = item
        let wantsScan = it.otp == "scan"
        if wantsScan { it.otp = "" }
        _item = State(initialValue: it)
        self.isNew = isNew
        _newPassword = State(initialValue: it.password)
        _url = State(initialValue: it.urls.first ?? "")
        _scanning = State(initialValue: wantsScan)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Panel {
                    VStack(spacing: 0) {
                        InkField(label: "Title", text: $item.title)
                        if item.kind == .login {
                            Hairline()
                            InkField(label: "Username or email", text: $item.username, mono: true)
                            UsernameChips(username: $item.username)
                            Hairline()
                            HStack(alignment: .bottom) {
                                InkField(label: "Password", text: $newPassword, mono: true)
                                CapsButton("New") { newPassword = PasswordGenerator.make(genOptions); showGen = true }.padding(.trailing, 6)
                            }
                            if showGen {
                                GeneratorControls(options: $genOptions).padding(.horizontal, 16).padding(.bottom, 8)
                                    .onChange(of: genOptions) { _, o in newPassword = PasswordGenerator.make(o) }
                            }
                            Hairline()
                            InkField(label: "Website", text: $url, mono: true)
                            Hairline()
                            HStack(alignment: .bottom) {
                                InkField(label: "2FA setup key", text: $item.otp, mono: true)
                                CapsButton("Scan") { scanning = true }.padding(.trailing, 6)
                            }
                        }
                    }
                }
                if item.kind != .login && item.kind != .note {
                    Panel {
                        VStack(spacing: 0) {
                            ForEach($item.fields) { $f in
                                InkField(label: f.label.isEmpty ? "Field" : f.label, text: $f.value, mono: f.secret)
                                Hairline()
                            }
                            Button("Add field") { item.fields.append(.init(label: "Other", value: "")) }
                                .font(.plex(15)).foregroundStyle(Ink.amber).frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                    .onAppear { if item.fields.isEmpty { item.fields = defaultFields(item.kind) } }
                }
                Panel { InkField(label: "Notes", text: $item.notes) }
                Panel { InkField(label: "Collection", text: $item.collection) }
                if !isNew {
                    Button("Delete \(item.kind.singular.lowercased())") { confirmDelete = true }
                        .buttonStyle(InkButtonStyle(kind: .destructive)).padding(.top, 12)
                }
            }
            .padding(16)
        }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
        .navigationTitle(isNew ? "NEW \(item.kind.singular.uppercased())" : "EDIT")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { CapsButton("Cancel", color: Ink.mid) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { CapsButton("Save", action: save) }
        }
        .confirmationDialog("Delete this item? This cannot be undone.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(item.id); dismiss() }
        }
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                guard let code else { return }
                item.otp = code
                if let comps = URLComponents(string: code), let label = comps.path.split(separator: "/").last {
                    let parts = label.removingPercentEncoding?.split(separator: ":") ?? []
                    if item.title.isEmpty, let issuer = comps.queryItems?.first(where: { $0.name == "issuer" })?.value ?? parts.first.map(String.init) { item.title = issuer }
                    if item.username.isEmpty, parts.count > 1 { item.username = String(parts[1]).trimmingCharacters(in: .whitespaces) }
                }
            }
        }
    }

    private func defaultFields(_ k: ItemKind) -> [VaultItem.Field] {
        switch k {
        case .card: return [.init(label: "Name on card", value: ""), .init(label: "Number", value: "", secret: true),
                            .init(label: "Expires", value: ""), .init(label: "Security code", value: "", secret: true)]
        case .bank: return [.init(label: "Bank", value: ""), .init(label: "Routing number", value: "", secret: true),
                            .init(label: "Account number", value: "", secret: true)]
        case .identity: return [.init(label: "Type", value: ""), .init(label: "Number", value: "", secret: true),
                                .init(label: "Name", value: ""), .init(label: "Expires", value: "")]
        case .personal: return [.init(label: "Name", value: ""), .init(label: "Email", value: ""), .init(label: "Phone", value: ""),
                                .init(label: "Address", value: "")]
        default: return []
        }
    }

    private func save() {
        var it = item
        if it.kind == .login {
            it.setPassword(newPassword)
            it.urls = url.isEmpty ? [] : [url]
            if it.title.isEmpty { it.title = Domain.host(from: url).map(Domain.base) ?? url }
        }
        it.fields = it.fields.filter { !$0.value.isEmpty }
        store.upsert(it)
        dismiss()
    }
}
