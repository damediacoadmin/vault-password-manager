import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: VaultStore
    var body: some View {
        Group {
            switch store.state {
            case .empty: SetupView()
            case .locked: UnlockView()
            case .unlocked: MainTabs()
            }
        }
        .background(Ink.bg.ignoresSafeArea())
    }
}

struct UnlockView: View {
    @EnvironmentObject var store: VaultStore
    @ObservedObject private var inbox = ExchangeInbox.shared
    @State private var usePassword = false
    @State private var master = ""
    @State private var error: String?
    @State private var showRecovery = false
    @State private var code = ""
    @State private var triedAuto = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Vault")
                Spacer()
                HStack(spacing: 6) { Circle().fill(Ink.muted).frame(width: 6, height: 6); Eyebrow("Locked") }
            }
            Spacer()
            Text("Locked.").font(.plex(40, .semibold, relativeTo: .largeTitle)).foregroundStyle(Ink.text)
            Text("Your logins, cards and notes are sealed on this iPhone.")
                .font(.plex(16)).foregroundStyle(Ink.mid).padding(.top, 10)
            if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red).padding(.top, 12) }
            if inbox.token != nil {
                Text("Items are waiting to move in from another app. Unlock to receive them.")
                    .font(.plex(14)).foregroundStyle(Ink.amber).padding(.top, 12)
            }
            Spacer()
            if usePassword || !store.hasBiometrics {
                VStack(spacing: 10) {
                    SecureField("", text: $master, prompt: Text("Master password").foregroundStyle(Ink.muted))
                        .font(.plex(16)).foregroundStyle(Ink.text)
                        .textContentType(.password).focused($focused).submitLabel(.go).onSubmit(unlockWithPassword)
                        .padding(.horizontal, 16).frame(height: 56)
                        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                    Button("Unlock", action: unlockWithPassword).buttonStyle(InkButtonStyle(kind: .primary, height: 52)).disabled(master.isEmpty)
                    Button("Forgot master password?") { showRecovery = true }
                        .font(.plex(14)).foregroundStyle(Ink.mid).frame(minHeight: 44)
                }
                .onAppear { focused = true }
            } else {
                Button(action: unlockWithBiometrics) {
                    HStack {
                        Text("Unlock with \(VaultCrypto.biometryName())")
                        Spacer()
                        Image(systemName: VaultCrypto.biometryName() == "Touch ID" ? "touchid" : "faceid").font(.system(size: 24, weight: .light))
                    }
                    .padding(.horizontal, 18)
                }
                .buttonStyle(InkButtonStyle(kind: .accentOutline, height: 64))
                Button("Use master password") { withAnimation { usePassword = true } }
                    .buttonStyle(InkButtonStyle(kind: .secondary, height: 52)).padding(.top, 10)
            }
            Hairline().padding(.top, 24)
            HStack {
                Eyebrow("AES-256"); Spacer(); Eyebrow("Secure Enclave"); Spacer(); Eyebrow("Auto-lock \(lockText)")
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
        .onAppear {
            if !triedAuto, store.hasBiometrics { triedAuto = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: unlockWithBiometrics) }
        }
        .alert("Unlock with recovery code", isPresented: $showRecovery) {
            TextField("XXXXX-XXXXX-...", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
            Button("Unlock") {
                do { try store.unlock(recoveryCode: code) } catch { self.error = error.localizedDescription }
                code = ""
            }
            Button("Cancel", role: .cancel) { code = "" }
        } message: { Text("Enter the code from your Recovery Kit, then set a new master password in Settings.") }
    }

    private var lockText: String {
        let s = VaultStore.autoLockSeconds
        return s == 0 ? "now" : s < 60 ? "\(s) s" : "\(s / 60) min"
    }

    private func unlockWithPassword() {
        let pw = master
        master = ""
        do { try store.unlock(master: pw); error = nil } catch { self.error = error.localizedDescription }
    }

    private func unlockWithBiometrics() {
        do { try store.unlockWithBiometrics(); error = nil }
        catch VaultError.cancelled { }
        catch { self.error = error.localizedDescription }
    }
}

struct SetupView: View {
    @EnvironmentObject var store: VaultStore
    @State private var master = ""
    @State private var confirm = ""
    @State private var useBio = true
    @State private var code: String?
    @State private var error: String?
    @State private var working = false
    @State private var joining = false

    var body: some View {
        if let code {
            RecoveryKitView(code: code) { store.finishSetup() }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Eyebrow("Vault · new")
                    Text("Create your vault.").font(.plex(34, .semibold, relativeTo: .largeTitle)).foregroundStyle(Ink.text).padding(.top, 40)
                    Text("Pick a master password only you know. Five random words works well. Nobody can reset it for you.")
                        .font(.plex(16)).foregroundStyle(Ink.mid).padding(.top, 10)
                    Panel {
                        VStack(spacing: 0) {
                            InkField(label: "Master password", text: $master, secure: true)
                            Hairline()
                            InkField(label: "Type it again", text: $confirm, secure: true)
                        }
                    }
                    .padding(.top, 28)
                    if !master.isEmpty {
                        Text("\(PasswordGenerator.strength(master).rawValue.uppercased()) · \(Int(PasswordGenerator.entropy(master))) BITS · 12 CHARACTERS MINIMUM")
                            .font(.mono(11, .medium)).tracking(1).foregroundStyle(master.count >= 12 ? Ink.muted : Ink.amber).padding(.top, 8)
                    }
                    if VaultCrypto.biometryAvailable {
                        Panel { InkToggle(isOn: $useBio, label: "Unlock with \(VaultCrypto.biometryName())").padding(.horizontal, 16).padding(.vertical, 12) }
                            .padding(.top, 12)
                    }
                    if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red).padding(.top, 12) }
                    Button(working ? "Creating..." : "Create vault", action: create)
                        .buttonStyle(InkButtonStyle(kind: .primary, height: 52))
                        .disabled(master.count < 12 || master != confirm || working)
                        .opacity(master.count < 12 || master != confirm ? 0.5 : 1)
                        .padding(.top, 24)
                    Button("Already use Vault on your Mac? Join it") { joining = true }
                        .font(.plex(15)).foregroundStyle(Ink.amber).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 8)
                }
                .padding(16)
            }
            .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
            .sheet(isPresented: $joining) { JoinVaultView(sync: nil) { joining = false } }
        }
    }

    private func create() {
        working = true
        let pw = master
        DispatchQueue.main.async {
            do { code = try store.create(master: pw, useBiometrics: useBio); master = ""; confirm = "" }
            catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

struct RecoveryKitView: View {
    let code: String
    var done: () -> Void
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow("Recovery kit")
                Text("Write this down.").font(.plex(34, .semibold, relativeTo: .largeTitle)).foregroundStyle(Ink.text).padding(.top, 40)
                Text("If you forget your master password, this code is the only way back in. Keep it on paper, somewhere safe. Vault will not show it again.")
                    .font(.plex(16)).foregroundStyle(Ink.mid).padding(.top, 10)
                Panel(fill: Ink.amberFill, stroke: Ink.amber) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(code.split(separator: "-").map(String.init), id: \.self) { g in
                            Text(g).font(.mono(26, .medium)).tracking(6).foregroundStyle(Ink.amber)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .textSelection(.enabled)
                }
                .padding(.top, 24)
                ShareLink(item: "Vault Recovery Kit\n\nRecovery code: \(code)\n\nKeep this on paper, offline.") {
                    Text("Print or save").frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle(kind: .secondary)).padding(.top, 12)
                Panel { InkToggle(isOn: $saved, label: "I wrote it down").padding(.horizontal, 16).padding(.vertical, 12) }
                    .padding(.top, 12)
                Button("Open my vault", action: done)
                    .buttonStyle(InkButtonStyle(kind: .primary, height: 52)).disabled(!saved).opacity(saved ? 1 : 0.5).padding(.top, 24)
            }
            .padding(16)
        }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
    }
}
