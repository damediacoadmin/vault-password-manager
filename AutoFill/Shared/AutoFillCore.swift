import AuthenticationServices
import SwiftUI

@MainActor
final class AutoFillModel: ObservableObject {
    enum Mode { case password, code }
    @Published var sites: [String] = []
    /// Friendly app name and App ID when signing in inside an app (iOS 26.2 and later).
    @Published var appName: String?
    var appID: String?

    func setServices(_ ids: [ASCredentialServiceIdentifier]) {
        AutoFillTrace.record(ids)
        sites = ids.map(\.identifier)
        if #available(iOS 26.2, macOS 26.2, *) {
            for s in ids {
                if let n = s.displayName, !n.isEmpty, appName == nil { appName = n }
                if s.type == .app, appID == nil { appID = s.identifier }
            }
            sites = ids.filter { $0.type != .app }.map(\.identifier)
        }
        if appName == nil, let id = appID { lookUpAppName(id) }
    }

    /// Turns an App ID ("TEAMID.com.example.app") into the app's App Store name. Only the app's
    /// bundle ID is sent, to Apple's public lookup service. Cached so each app is looked up once.
    private func lookUpAppName(_ appID: String) {
        let parts = appID.split(separator: ".")
        let bundle = parts.count > 1 && parts[0].count == 10 ? parts.dropFirst().joined(separator: ".") : appID
        let cacheKey = "appName." + bundle
        if let cached = UserDefaults.standard.string(forKey: cacheKey) { appName = cached; return }
        guard var c = URLComponents(string: "https://itunes.apple.com/lookup") else { return }
        c.queryItems = [URLQueryItem(name: "bundleId", value: bundle)]
        guard let url = c.url else { return }
        Task { @MainActor in
            var req = URLRequest(url: url); req.timeoutInterval = 4
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let first = (obj["results"] as? [[String: Any]])?.first,
                  let name = first["trackName"] as? String, !name.isEmpty else { return }
            var short = name
            for sep in [" - ", " – ", " — ", ": ", " | "] { short = short.components(separatedBy: sep).first ?? short }
            short = short.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(short, forKey: cacheKey)
            self.appName = short
            self.objectWillChange.send()
        }
    }
    @Published var mode: Mode = .password
    @Published var unlocked = false
    @Published var error: String?
    @Published var needsPassword = false
    var directID: UUID?
    let store = VaultStore()
    // Passkeys
    struct PasskeySignIn { let rp: String; let clientDataHash: Data; let allowed: [Data] }
    struct PasskeyCreate { let rp: String; let userName: String; let userHandle: Data; let clientDataHash: Data }
    @Published var signIn: PasskeySignIn?
    var create: PasskeyCreate?
    var directCredentialID: Data?
    var finishAssertion: (ASPasskeyAssertionCredential) -> Void = { _ in }
    // Save requests from the system (iOS 26.2+)
    struct SaveRequest { let username: String; let password: String }
    var saveRequest: SaveRequest?
    /// New passwords are also put on the clipboard for 90 seconds so a "confirm password" box can be pasted into.
    var copyForConfirmBox: String?
    var finishSave: () -> Void = {}

    private func completeSave() {
        guard let r = saveRequest else { return }
        let existing = matches.first { $0.username.caseInsensitiveCompare(r.username) == .orderedSame }
        if var it = existing {
            it.setPassword(r.password)
            if let n = appName, it.title.isEmpty || it.title.contains(".") { it.title = n }
            store.upsert(it)
        } else {
            var urls: [String] = []
            if let h = Domain.host(from: host) { urls.append(h) }
            if let a = appID { urls.append("app:" + a) }
            let title = appName ?? AutoFillView.siteName(host)
            store.upsert(VaultItem(kind: .login, title: title.isEmpty ? r.username : title, username: r.username,
                                   password: r.password, urls: urls))
        }
        CredentialIdentities.sync(store.items)
        store.lock()
        finishSave()
    }
    var finishRegistration: (ASPasskeyRegistrationCredential) -> Void = { _ in }

    var passkeyMatches: [Passkey] {
        guard let s = signIn else { return [] }
        return store.passkeys(for: s.rp).filter { s.allowed.isEmpty || s.allowed.contains($0.credentialID) }
    }

    func usePasskey(_ pk: Passkey) {
        guard let s = signIn else { return }
        do {
            let a = try WebAuthn.assert(pk, clientDataHash: s.clientDataHash)
            finishAssertion(ASPasskeyAssertionCredential(userHandle: pk.userHandle, relyingParty: pk.rpID, signature: a.signature,
                                                         clientDataHash: s.clientDataHash, authenticatorData: a.authData, credentialID: pk.credentialID))
        } catch { self.error = "That passkey could not be used." }
        store.lock()
    }

    private func completeCreate() {
        guard let c = create else { return }
        let pk = WebAuthn.newPasskey(rpID: c.rp, userName: c.userName, userHandle: c.userHandle)
        do {
            let att = try WebAuthn.attestationObject(for: pk)
            store.addPasskey(pk)
            finishRegistration(ASPasskeyRegistrationCredential(relyingParty: c.rp, clientDataHash: c.clientDataHash,
                                                               credentialID: pk.credentialID, attestationObject: att))
        } catch { self.error = "The passkey could not be created." }
        store.lock()
    }
    var cancel: () -> Void = {}
    var finish: (VaultItem) -> Void = { _ in }
    var finishCode: (String) -> Void = { _ in }

    var host: String { create?.rp ?? signIn?.rp ?? sites.compactMap(Domain.host(from:)).first ?? sites.first ?? "" }

    var matches: [VaultItem] {
        store.items.filter { it in
            it.kind == .login && (it.urls.contains { u in sites.contains { Domain.matches(saved: u, requested: $0) } }
                                  || (appID.map { id in it.urls.contains("app:" + id) } ?? false))
        }
            .filter { mode == .password || !$0.otp.isEmpty }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    func start() {
        guard !unlocked else { return }
        if store.hasBiometrics {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.unlockBio() }
        } else { needsPassword = true }
    }

    func unlockBio() {
        do { try store.unlockWithBiometrics(reason: "fill your login for \(host)"); didUnlock() }
        catch VaultError.cancelled { needsPassword = true }
        catch { self.error = error.localizedDescription; needsPassword = true }
    }

    func unlock(master: String) {
        do { try store.unlock(master: master); didUnlock() } catch { self.error = error.localizedDescription }
    }

    private func didUnlock() {
        unlocked = true
        error = nil
        if create != nil { completeCreate(); return }
        if saveRequest != nil { completeSave(); return }
        if let cid = directCredentialID, let pk = passkeyMatches.first(where: { $0.credentialID == cid }) { usePasskey(pk); return }
        if signIn == nil, let id = directID, let it = store.items.first(where: { $0.id == id }) { pick(it); return }
        // Two-step sign-ins (email first, password on the next screen): reuse the login picked on this
        // site in the last 3 minutes, so the password step is just Face ID.
        if mode == .password, signIn == nil, let last = LastPick.recent(for: host),
           let it = matches.first(where: { $0.id == last }) { pick(it) }
    }

    /// Usernames and emails you use most, for one-tap picking when creating a login.
    var suggestedUsernames: [String] { store.usernameSuggestions() }

    /// Saves a brand-new login for this site and fills it straight away.
    func createAndFill(title: String, username: String, password: String) {
        var urls: [String] = []
        if let h = Domain.host(from: host) { urls.append(h) }
        if let a = appID { urls.append("app:" + a) }
        if urls.isEmpty, let s = sites.first { urls.append(s) }
        var it = VaultItem(kind: .login, title: title, username: username, password: password, urls: urls)
        it.lastUsed = Date()
        store.upsert(it)
        CredentialIdentities.sync(store.items)
        copyForConfirmBox = password
        pick(it)
    }

    func pick(_ item: VaultItem) {
        if mode == .password { LastPick.save(item.id, for: host); CredentialIdentities.bump(item) }
        if mode == .code, let t = TOTP(item.otp) { finishCode(t.code()) } else { finish(item) }
        store.lock()
    }
}

struct AutoFillView: View {
    @ObservedObject var model: AutoFillModel
    @State private var query = ""
    @State private var master = ""
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Vault / \(model.appName ?? model.host)")
                Spacer()
                CapsButton("Cancel", color: Ink.mid) { model.store.lock(); model.cancel() }
            }
            if model.unlocked { list } else { locked }
        }
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Ink.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Ink.amber)
    }

    private var locked: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.create != nil ? "Save a new passkey" : model.saveRequest != nil ? "Save this login" : "Unlock to fill").font(.plex(28, .semibold)).foregroundStyle(Ink.text).padding(.top, 24)
            Text(model.host).font(.mono(15)).foregroundStyle(Ink.muted)
            if model.needsPassword {
                SecureField("", text: $master, prompt: Text("Master password").foregroundStyle(Ink.muted))
                    .font(.plex(16)).foregroundStyle(Ink.text).textContentType(.password).textFieldStyle(.plain)
                    .padding(.horizontal, 16).frame(height: 52)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                    .onSubmit { model.unlock(master: master); master = "" }
                Button("Unlock") { model.unlock(master: master); master = "" }
                    .buttonStyle(InkButtonStyle(kind: .primary)).disabled(master.isEmpty)
                if model.store.hasBiometrics {
                    Button("Try \(VaultCrypto.biometryName())") { model.unlockBio() }.buttonStyle(InkButtonStyle(kind: .accentOutline))
                }
            }
            if let e = model.error { Text(e).font(.plex(14)).foregroundStyle(Ink.red) }
            Spacer()
        }
    }

    private var list: some View {
        let exact = model.matches
        let others = query.isEmpty ? [] : model.store.items.filter {
            $0.kind == .login && !exact.contains($0) &&
            ($0.title.localizedCaseInsensitiveContains(query) || $0.username.localizedCaseInsensitiveContains(query) || $0.urls.joined().localizedCaseInsensitiveContains(query))
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if creating {
                    CreateLoginForm(model: model, siteName: model.appName ?? Self.siteName(model.host)) { creating = false }
                } else {
                Hairline().padding(.top, 8)
                ForEach(model.passkeyMatches) { pk in
                    Button { model.usePasskey(pk) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pk.userName).font(.plex(17, .medium)).foregroundStyle(Ink.text).lineLimit(1)
                                Text("passkey · \(pk.rpID)").font(.mono(13)).foregroundStyle(Ink.muted)
                            }
                            Spacer()
                            Tag(text: "PASSKEY")
                        }
                        .frame(minHeight: 64).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Hairline()
                }
                if exact.isEmpty && model.passkeyMatches.isEmpty {
                    Text("No logins saved for \(model.host) yet.").font(.plex(15)).foregroundStyle(Ink.mid).frame(minHeight: 52)
                }
                if model.mode == .password {
                    Button { creating = true } label: {
                        HStack { Image(systemName: "plus"); Text("Create login for \(model.appName ?? Self.siteName(model.host))") }
                    }
                    .buttonStyle(InkButtonStyle(kind: exact.isEmpty ? .primary : .accentOutline))
                    .padding(.vertical, 12)
                    Hairline()
                }
                ForEach(Array(exact.enumerated()), id: \.element.id) { i, it in row(it, primary: i == 0); Hairline() }
                Text(model.mode == .password ? "Only logins saved for \(model.host) are shown. The one-time code is copied for the next screen."
                                             : "Only codes saved for \(model.host) are shown.")
                    .font(.plex(13)).foregroundStyle(Ink.muted).padding(.top, 12)
                searchField.padding(.top, 20)
                if !others.isEmpty {
                    Eyebrow("Saved for other sites", color: Ink.amber).padding(.top, 16).padding(.bottom, 8)
                    Hairline()
                    ForEach(others) { row($0, primary: false); Hairline() }
                    Text("Check the address bar before filling one of these.").font(.plex(13)).foregroundStyle(Ink.muted).padding(.top, 8)
                }
                }
            }
        }
    }

    static func siteName(_ host: String) -> String {
        host.isEmpty ? "" : VaultItem(title: host, urls: [host]).displayName
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted)
            TextField("", text: $query, prompt: Text("Search every login").foregroundStyle(Ink.muted))
                .font(.plex(16)).foregroundStyle(Ink.text).autocorrectionDisabled().textFieldStyle(.plain)
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
    }

    private func row(_ it: VaultItem, primary: Bool) -> some View {
        Button { model.pick(it) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.username.isEmpty ? it.title : it.username).font(.plex(17, .medium)).foregroundStyle(Ink.text).lineLimit(1)
                    Text(it.title + (it.lastUsed.map { Calendar.current.isDateInToday($0) ? " · last used today" : "" } ?? ""))
                        .font(.mono(13)).foregroundStyle(Ink.muted).lineLimit(1)
                }
                Spacer()
                if model.mode == .code, let t = TOTP(it.otp) {
                    Text(TOTP.pretty(t.code())).font(.mono(17, .medium)).foregroundStyle(Ink.amber)
                } else {
                    Tag(text: "FILL", solid: primary)
                }
            }
            .frame(minHeight: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Remembers which login was filled on a site for 3 minutes. Stored in the shared Keychain,
/// holds only the site name and an item number, never a password.
enum LastPick {
    private struct Entry: Codable { var site: String; var id: UUID; var at: Date }

    static func save(_ id: UUID, for host: String) {
        let e = Entry(site: Domain.base(host), id: id, at: Date())
        if let d = try? JSONEncoder().encode(e) { try? VaultKeychain.write("lastPick", d) }
    }

    static func recent(for host: String) -> UUID? {
        guard let d = try? VaultKeychain.read("lastPick"), let e = try? JSONDecoder().decode(Entry.self, from: d),
              e.site == Domain.base(host), Date().timeIntervalSince(e.at) < 180 else { return nil }
        return e.id
    }
}

/// New login for the site being signed up on: name filled in, usernames as chips, strong password ready.
struct CreateLoginForm: View {
    @ObservedObject var model: AutoFillModel
    let siteName: String
    var cancel: () -> Void
    @State private var title = ""
    @State private var username = ""
    @State private var options = PasswordGenerator.saved
    @State private var password = PasswordGenerator.make(PasswordGenerator.saved)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New login").font(.plex(24, .semibold)).foregroundStyle(Ink.text).padding(.top, 12)
            field(siteName.isEmpty ? "App or site name (this app did not share it)" : "Name", $title, mono: false)
            field("Username or email", $username, mono: true)
            let chips = model.suggestedUsernames
            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips, id: \.self) { u in
                            Button { username = u } label: {
                                Text(u).font(.mono(13)).lineLimit(1)
                                    .padding(.horizontal, 12).frame(height: 36)
                                    .foregroundStyle(username == u ? Ink.bg : Ink.text)
                                    .background(username == u ? Ink.amber : Ink.panel, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(username == u ? Ink.amber : Ink.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Password")
                Text(password).font(.mono(17, .medium)).foregroundStyle(Ink.amber).lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Ink.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                Button("New one") { password = PasswordGenerator.make(options) }.buttonStyle(InkButtonStyle(kind: .secondary, height: 40))
                GeneratorControls(options: $options).padding(.top, 4)
                    .onChange(of: options) { _, o in password = PasswordGenerator.make(o) }
            }
            Text("Vault fills the password box and copies the password for 90 seconds, so you can paste it into a \"confirm password\" box.")
                .font(.plex(12)).foregroundStyle(Ink.muted)
            Button("Save and fill") {
                model.createAndFill(title: title.isEmpty ? siteName : title, username: username, password: password)
            }
            .buttonStyle(InkButtonStyle(kind: .primary, height: 52))
            .disabled(username.isEmpty)
            .opacity(username.isEmpty ? 0.5 : 1)
            Button("Back", action: cancel).font(.plex(15)).foregroundStyle(Ink.mid).frame(maxWidth: .infinity, minHeight: 44)
        }
        .onAppear { if title.isEmpty { title = siteName }; if username.isEmpty { username = model.suggestedUsernames.first ?? "" } }
        .onChange(of: model.appName) { _, n in if title.isEmpty, let n { title = n } }
    }

    private func field(_ label: String, _ text: Binding<String>, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(label)
            TextField("", text: text).textFieldStyle(.plain)
                .font(mono ? .mono(16) : .plex(16)).foregroundStyle(Ink.text).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .padding(.horizontal, 14).frame(height: 48)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
        }
    }
}

#if os(iOS)
/// Turns a site's password rules ("minlength: 8; maxlength: 20; required: digit; ...") into
/// three suggestions for the system: strong, letters and numbers only, and a word passphrase.
@available(iOS 26.2, *)
enum PasswordRules {
    static func suggestions(rules: String) -> [ASGeneratedPassword] {
        var minLen = 8, maxLen = 64
        var specialAllowed = true
        let lower = rules.lowercased()
        for part in lower.split(separator: ";") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            if kv[0] == "minlength", let n = Int(kv[1]) { minLen = n }
            if kv[0] == "maxlength", let n = Int(kv[1]) { maxLen = n }
        }
        if !lower.isEmpty && !lower.contains("special") && !lower.contains("[") { specialAllowed = false }
        var o = PasswordGenerator.saved
        o.style = .characters
        o.length = min(max(o.length, minLen, 12), max(maxLen, 8))
        o.symbols = specialAllowed && o.symbols
        var plain = o; plain.symbols = false
        var words = PasswordGenerator.saved; words.style = .words
        var out = [ASGeneratedPassword(kind: .strong, value: PasswordGenerator.make(o)),
                   ASGeneratedPassword(kind: .alphanumeric, value: PasswordGenerator.make(plain))]
        let phrase = PasswordGenerator.make(words)
        if phrase.count <= maxLen && (specialAllowed || !phrase.contains("-")) {
            out.append(ASGeneratedPassword(kind: .passphrase, value: phrase))
        }
        return out
    }
}
#endif

/// Remembers what iOS told Vault about the last sign-in screen (site or app names only), so a missing
/// app name can be diagnosed from Vault's Settings.
enum AutoFillTrace {
    static func record(_ ids: [ASCredentialServiceIdentifier]) {
        var lines = ["\(Date().formatted(date: .omitted, time: .standard))  \(ids.count) identifier(s)"]
        for s in ids {
            var kind = s.type == .domain ? "domain" : s.type == .URL ? "url" : "other"
            var name = ""
            if #available(iOS 26.2, macOS 26.2, *) {
                if s.type == .app { kind = "app" }
                name = s.displayName ?? ""
            }
            lines.append("\(kind): \(s.identifier)\(name.isEmpty ? "" : "  name: \(name)")")
        }
        try? VaultKeychain.write("afTrace", Data(lines.joined(separator: "\n").utf8))
    }
    static var last: String { (try? VaultKeychain.read("afTrace")).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}
