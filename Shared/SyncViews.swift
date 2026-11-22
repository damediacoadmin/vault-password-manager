import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR code drawn on the device. It carries only the sync code; joining still needs the master password.
struct QRCodeImage: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            Image(decorative: img, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Sync QR code")
        }
    }
    static func make(_ s: String) -> CGImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(out, from: out.extent)
    }
}

/// Live sync badge for headers: amber dot when synced, grey when off or offline.
struct SyncBadge: View {
    @ObservedObject var sync: Sync
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Eyebrow(sync.summary, color: sync.state == .synced ? Ink.text : Ink.muted)
        }
        .accessibilityElement(children: .combine)
    }
    private var color: Color {
        switch sync.state { case .synced: return Ink.amber; case .syncing: return Ink.mid; case .offline: return Ink.red; case .off: return Ink.muted }
    }
}

enum JoinLink {
    static func make(_ code: String) -> String { "vault-join:" + code }
    static func code(from s: String) -> String? {
        guard s.lowercased().hasPrefix("vault-join:") else { return nil }
        let c = String(s.dropFirst("vault-join:".count))
        return c.filter(\.isHexDigit).count == 32 ? c : nil
    }
}

/// Sync settings block used on iPhone and Mac.
struct SyncPanel: View {
    @EnvironmentObject var store: VaultStore
    @ObservedObject var sync: Sync
    @State private var joining = false
    @State private var linkingChrome = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Sync")
            Panel {
                VStack(spacing: 0) {
                    InkToggle(isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }),
                              label: "Sync with your other devices", detail: "Scrambled on this device first. The server only sees ciphertext.")
                        .padding(.horizontal, 16).padding(.vertical, 12)
                    if sync.enabled {
                        Hairline()
                        HStack {
                            Text("Status").font(.plex(15)).foregroundStyle(Ink.text)
                            Spacer()
                            SyncBadge(sync: sync)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 48)
                        Hairline()
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow("Connected devices")
                            deviceRow(Sync.thisDevice, me: true)
                            ForEach(sync.otherDevices) { deviceRow($0, me: false) }
                            if sync.otherDevices.isEmpty {
                                Text("No other device yet. Join from your other device to connect it.").font(.plex(12)).foregroundStyle(Ink.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        if let code = sync.syncCode {
                            Hairline()
                            VStack(alignment: .leading, spacing: 6) {
                                Eyebrow("Sync code for your other device")
                                Text(code).font(.mono(15, .medium)).foregroundStyle(Ink.amber).textSelection(.enabled)
                                QRCodeImage(text: JoinLink.make(code)).frame(width: 180, height: 180).padding(.vertical, 6)
                                Text("On the other device, choose Join a vault, then scan this QR code or type the code, and enter your master password.")
                                    .font(.plex(12)).foregroundStyle(Ink.muted)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        }
                    }
                    #if os(iOS) && VAULT_APP
                    Hairline()
                    Button { linkingChrome = true } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Link Chrome").font(.plex(15)).foregroundStyle(Ink.text)
                                Text("Scan the QR code in the Vault Chrome extension").font(.plex(12)).foregroundStyle(Ink.muted)
                            }
                            Spacer(); Text("›").foregroundStyle(Ink.muted)
                        }
                        .padding(.horizontal, 16).frame(minHeight: 60).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #endif
                    Hairline()
                    Button { joining = true } label: {
                        HStack { Text("Join a vault from another device").font(.plex(15)).foregroundStyle(Ink.text); Spacer(); Text("›").foregroundStyle(Ink.muted) }
                            .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $joining) { JoinVaultView(sync: sync) { joining = false } }
        #if os(iOS) && VAULT_APP
        .fullScreenCover(isPresented: $linkingChrome) { LinkChromeView(sync: sync) { linkingChrome = false } }
        #endif
    }

    private func deviceRow(_ d: SyncedDevice, me: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: d.platform == "Mac" ? "laptopcomputer" : d.platform == "Chrome" ? "globe" : "iphone").foregroundStyle(Ink.mid).frame(width: 20)
            Text(me ? "\(d.name) (this device)" : d.name).font(.plex(14)).foregroundStyle(Ink.text)
            Spacer()
            Text(me ? "now" : d.lastSeen.formatted(.relative(presentation: .named))).font(.mono(12)).foregroundStyle(Ink.muted)
        }
    }
}

struct JoinVaultView: View {
    @EnvironmentObject var store: VaultStore
    var sync: Sync?
    var done: () -> Void
    @State private var code = ""
    @State private var master = ""
    @State private var working = false
    @State private var error: String?
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Join a vault")
            Text("Use the same vault on this device.").font(.plex(24, .semibold)).foregroundStyle(Ink.text)
            Text("Scan the QR code or type the sync code shown in Settings on your other device, then enter your master password. Anything already on this device is merged in.")
                .font(.plex(14)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            #if os(iOS) && VAULT_APP
            Button("Scan QR code from your other device") { scanning = true }
                .buttonStyle(InkButtonStyle(kind: .accentOutline))
            #endif
            field("Sync code", $code, secure: false)
            field("Master password", $master, secure: true)
            if let error { Text(error).font(.plex(13)).foregroundStyle(Ink.red) }
            HStack(spacing: 8) {
                Button("Cancel", action: done).buttonStyle(InkButtonStyle(kind: .secondary))
                Button(working ? "Joining..." : "Join") { join() }.buttonStyle(InkButtonStyle(kind: .primary))
                    .disabled(working || master.isEmpty || code.filter(\.isHexDigit).count != 32)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 380)
        .background(Ink.bg)
        .preferredColorScheme(.dark)
        #if os(iOS) && VAULT_APP
        .dismissesKeyboard()
        #endif
        #if os(iOS) && VAULT_APP
        .fullScreenCover(isPresented: $scanning) {
            QRScannerView(title: "Scan sync QR code", hint: "On your other device, open Vault Settings and turn on Sync to show its QR code.",
                          accept: { JoinLink.code(from: $0) != nil }) { s in
                scanning = false
                if let s, let c = JoinLink.code(from: s) { code = c }
            }
        }
        #endif
    }

    private func field(_ label: String, _ text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(label)
            Group { if secure { SecureField("", text: text) } else { TextField("", text: text) } }
                .textFieldStyle(.plain).font(.mono(16)).foregroundStyle(Ink.text).autocorrectionDisabled()
                .padding(.horizontal, 14).frame(height: 48)
                .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
        }
    }

    private func join() {
        working = true; error = nil
        let pw = master
        Task {
            do {
                try await Sync.join(code: code, master: pw, store: store, useBiometrics: true)
                sync?.setEnabled(true)
                master = ""
                done()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

/// Shows the last transfer steps (no secrets), only when there are any.
struct TransferTrace: View {
    @ObservedObject var inbox = ExchangeInbox.shared
    var body: some View {
        if !inbox.trace.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Last transfer from another app")
                ForEach(Array(inbox.trace.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.mono(11)).foregroundStyle(Ink.mid).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
    }
}

/// Last AutoFill request as iOS described it (site or app names only).
struct AutoFillTraceView: View {
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Last AutoFill request")
            Panel {
                Text(text.isEmpty ? "Nothing yet. Tap a password box in any app, open Vault, then come back here." : text)
                    .font(.mono(12)).foregroundStyle(Ink.mid).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .padding(.top, 12)
        .onAppear(perform: reload)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in reload() }
        #endif
    }
    private func reload() { text = (try? VaultKeychain.read("afTrace")).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

#if os(iOS) && VAULT_APP
import LocalAuthentication

/// Scan the QR code the Chrome extension shows, confirm with Face ID, and hand Chrome the key.
struct LinkChromeView: View {
    @EnvironmentObject var store: VaultStore
    @ObservedObject var sync: Sync
    var done: () -> Void
    @State private var request: ChromeLink.Request?
    @State private var working = false
    @State private var linked = false
    @State private var error: String?

    var body: some View {
        if let request {
            VStack(alignment: .leading, spacing: 0) {
                HStack { Eyebrow("Link Chrome"); Spacer(); CapsButton("Close", color: Ink.text, action: done) }
                Spacer()
                Text(linked ? "Chrome is linked." : "Link Chrome to your vault?")
                    .font(.plex(30, .semibold, relativeTo: .largeTitle)).foregroundStyle(Ink.text)
                Text(linked ? "Chrome now fills, saves and syncs your logins. You can unlink it from the Vault button in Chrome."
                            : "Chrome gets its own end-to-end encrypted copy of your logins and keeps it in sync. The sync server never sees your passwords.")
                    .font(.plex(16)).foregroundStyle(Ink.mid).padding(.top, 10).fixedSize(horizontal: false, vertical: true)
                if !linked {
                    Text("Only continue if you just clicked Link with iPhone in Chrome yourself.")
                        .font(.plex(14)).foregroundStyle(Ink.amber).padding(.top, 14).fixedSize(horizontal: false, vertical: true)
                }
                if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red).padding(.top, 12) }
                Spacer()
                if linked {
                    Button("Done", action: done).buttonStyle(InkButtonStyle(kind: .primary, height: 52))
                } else {
                    Button(working ? "Linking..." : "Link with \(VaultCrypto.biometryName())") { link(request) }
                        .buttonStyle(InkButtonStyle(kind: .primary, height: 52)).disabled(working)
                    Button("Cancel", action: done).buttonStyle(InkButtonStyle(kind: .secondary, height: 52)).padding(.top, 10)
                }
            }
            .padding(16)
            .background(Ink.bg.ignoresSafeArea())
            .preferredColorScheme(.dark)
        } else {
            QRScannerView(title: "Scan Chrome's QR code",
                          hint: "In Chrome, click the Vault button, then Link with iPhone. Point the camera at the code.",
                          accept: { ChromeLink.parse($0) != nil }) { s in
                if let s, let r = ChromeLink.parse(s) { request = r } else { done() }
            }
        }
    }

    private func link(_ r: ChromeLink.Request) {
        working = true; error = nil
        Task {
            do {
                let ctx = LAContext()
                let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
                    ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
                guard try await ctx.evaluatePolicy(policy, localizedReason: "link Chrome to your vault") else { throw VaultError.cancelled }
                await sync.syncNow()
                try await ChromeLink.send(r, store: store, deviceName: "iPhone")
                linked = true
            } catch VaultError.cancelled {
            } catch let e as LAError where e.code == .userCancel || e.code == .appCancel || e.code == .systemCancel {
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}
#endif
