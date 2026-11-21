import AuthenticationServices
import SwiftUI

@MainActor
final class AutoFillModel: ObservableObject {
    enum Mode { case password, code }
    @Published var sites: [String] = []
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
        store.items.filter { it in it.kind == .login && it.urls.contains { u in sites.contains { Domain.matches(saved: u, requested: $0) } } }
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
        if let cid = directCredentialID, let pk = passkeyMatches.first(where: { $0.credentialID == cid }) { usePasskey(pk); return }
        if signIn == nil, let id = directID, let it = store.items.first(where: { $0.id == id }) { pick(it); return }
        // Two-step sign-ins (email first, password on the next screen): reuse the login picked on this
        // site in the last 3 minutes, so the password step is just Face ID.
        if mode == .password, signIn == nil, let last = LastPick.recent(for: host),
           let it = matches.first(where: { $0.id == last }) { pick(it) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Vault / \(model.host)")
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
            Text(model.create != nil ? "Save a new passkey" : "Unlock to fill").font(.plex(28, .semibold)).foregroundStyle(Ink.text).padding(.top, 24)
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
                    Text("No logins saved for \(model.host).").font(.plex(15)).foregroundStyle(Ink.mid).frame(minHeight: 60)
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
