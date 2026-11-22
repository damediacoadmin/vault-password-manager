import SwiftUI
import UniformTypeIdentifiers

struct HealthView: View {
    @EnvironmentObject var store: VaultStore
    var embedded = false
    @State private var breached: Set<UUID> = []
    @State private var checkedAt: Date?
    @State private var checking = false
    @State private var showing: ListBox?

    var body: some View {
        let content = ScrollView { body(HealthReport.build(store.items, breachedIDs: breached)) }
            .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
            .task { if checkedAt == nil { check() } }
            .sheet(item: $showing) { box in
                NavigationStack { ItemListView(title: box.title, ids: box.ids) }
            }
        if embedded { content.navigationTitle("HEALTH").navigationBarTitleDisplayMode(.inline) }
        else { NavigationStack { content.toolbar(.hidden, for: .navigationBar) } }
    }

    private func body(_ r: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Health")
                Spacer()
                Eyebrow(checking ? "Checking breaches..." : checkedAt.map { "Breach check \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            }
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("\(r.score)").font(.mono(88, .medium, relativeTo: .largeTitle)).tracking(-4).foregroundStyle(Ink.text)
                Text(r.toFix == 0 ? "out of 100.\nNothing to fix." : "out of 100.\nFix \(r.toFix) to reach 100.")
                    .font(.plex(15)).foregroundStyle(Ink.mid)
            }
            .padding(.top, 20)
            .accessibilityElement(children: .combine)
            ScoreBar(total: r.total, bad: r.toFix).padding(.top, 18)
            Eyebrow("\(r.total) logins · \(r.total - r.toFix) ok · \(r.toFix) to fix").padding(.top, 8)
            VStack(spacing: 0) {
                Hairline()
                row("Found in a breach", r.breached)
                row("Reused", r.reused.flatMap { $0 })
                row("Weak", r.weak)
                row("Older than 2 years", r.old, quiet: true)
            }
            .padding(.top, 24)
            Text("Breach checks send only the first 5 characters of a scrambled fingerprint, never a password.")
                .font(.plex(13)).foregroundStyle(Ink.muted).padding(.top, 14)
            Button(checking ? "Checking..." : "Check for breaches now", action: check)
                .buttonStyle(InkButtonStyle(kind: .secondary)).disabled(checking || store.items.isEmpty).padding(.top, 16)
        }
        .padding(16)
    }

    private func row(_ title: String, _ items: [VaultItem], quiet: Bool = false) -> some View {
        Button { if !items.isEmpty { showing = ListBox(title: title, ids: items.map(\.id)) } } label: {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.plex(16)).foregroundStyle(Ink.text)
                    Spacer()
                    Text("\(items.count)").font(.mono(17, .medium))
                        .foregroundStyle(items.isEmpty ? Ink.muted : quiet ? Ink.mid : Ink.amber)
                    Text("›").foregroundStyle(items.isEmpty ? .clear : Ink.muted).frame(width: 14)
                }
                .frame(minHeight: 56)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func check() {
        guard !checking, !store.items.isEmpty else { return }
        checking = true
        let items = store.items
        Task {
            breached = await BreachCheck.breachedIDs(items)
            checkedAt = Date()
            checking = false
        }
    }
}

struct ListBox: Identifiable { let id = UUID(); let title: String; let ids: [UUID] }

struct ItemListView: View {
    @EnvironmentObject var store: VaultStore
    let title: String
    let ids: [UUID]
    /// Live from the store, so a deleted or fixed login drops out right away.
    private var items: [VaultItem] { ids.compactMap { id in store.items.first { $0.id == id } } }
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Hairline()
                ForEach(items) { it in
                    NavigationLink { ItemDetailView(id: it.id) } label: { ItemRow(item: it) }.buttonStyle(.plain)
                    Hairline()
                }
            }
            .padding(16)
        }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
        .navigationTitle(title.uppercased()).navigationBarTitleDisplayMode(.inline)
        .toolbar { CapsButton("Done") { dismiss() } }
    }
}

/// 50 segments: light for healthy logins, amber for ones to fix.
struct ScoreBar: View {
    let total: Int
    let bad: Int
    var body: some View {
        let n = 50
        let badCells = total == 0 ? 0 : max(bad > 0 ? 1 : 0, Int((Double(bad) / Double(total) * Double(n)).rounded()))
        HStack(spacing: 2) {
            ForEach(0..<n, id: \.self) { i in Rectangle().fill(i >= n - badCells ? Ink.amber : Ink.text).frame(height: 14) }
        }
        .accessibilityHidden(true)
    }
}

struct GeneratorView: View {
    @State private var options = PasswordGenerator.saved
    @State private var value = PasswordGenerator.make(PasswordGenerator.saved)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Eyebrow("Generate"); Spacer(); Eyebrow("\(Int(PasswordGenerator.entropy(value))) bits") }
                    HStack(spacing: 0) {
                        ForEach(PasswordGenerator.Options.Style.allCases, id: \.self) { s in
                            Button { options.style = s } label: {
                                Text(s.rawValue).font(.plex(15, .medium)).foregroundStyle(options.style == s ? Ink.text : Ink.mid)
                                    .frame(maxWidth: .infinity).frame(height: 44).background(options.style == s ? Ink.panelHi : .clear)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(options.style == s ? .isSelected : [])
                            if s == .words { Rectangle().fill(Ink.line).frame(width: 1) }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
                    Panel {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(colored(value)).font(.mono(18, .medium)).minimumScaleFactor(0.7).lineLimit(2).textSelection(.enabled)
                            HStack(spacing: 8) {
                                Button("New one") { value = PasswordGenerator.make(options) }.buttonStyle(InkButtonStyle(kind: .secondary))
                                Button("Copy") { Clipboard.copy(value) }.buttonStyle(InkButtonStyle(kind: .primary))
                            }
                        }
                        .padding(16)
                    }
                    Panel {
                        VStack(spacing: 0) {
                            if options.style == .words {
                                stepper("Words", $options.wordCount, 3...10)
                                Hairline()
                                InkToggle(isOn: $options.capitals, label: "Capital letters").padding(.horizontal, 16).frame(minHeight: 56)
                                Hairline()
                                InkToggle(isOn: $options.number, label: "Add a number").padding(.horizontal, 16).frame(minHeight: 56)
                            } else {
                                stepper("Length", $options.length, 12...64)
                                Hairline()
                                InkToggle(isOn: $options.symbols, label: "Symbols").padding(.horizontal, 16).frame(minHeight: 56)
                            }
                        }
                    }
                    Text(options.style == .words ? "Easy to type on a TV, and it would take centuries to guess." : "Random characters pack the most strength into the fewest letters.")
                        .font(.plex(13)).foregroundStyle(Ink.muted)
                }
                .padding(16)
            }
            .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: options) { _, o in value = PasswordGenerator.make(o); PasswordGenerator.saved = o }
        }
    }

    private func stepper(_ label: String, _ v: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack(spacing: 0) {
            Text(label).font(.plex(16)).foregroundStyle(Ink.text)
            Spacer()
            Button { if v.wrappedValue > range.lowerBound { v.wrappedValue -= 1 } } label: { Text("−").font(.mono(20)).frame(width: 44, height: 44) }
                .accessibilityLabel("Fewer")
            Text("\(v.wrappedValue)").font(.mono(17, .medium)).frame(minWidth: 28)
            Button { if v.wrappedValue < range.upperBound { v.wrappedValue += 1 } } label: { Text("+").font(.mono(20)).frame(width: 44, height: 44) }
                .accessibilityLabel("More")
        }
        .foregroundStyle(Ink.text).buttonStyle(.plain)
        .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 56)
    }

    private func colored(_ s: String) -> AttributedString {
        var a = AttributedString()
        for part in s.split(separator: "-", omittingEmptySubsequences: false).enumerated() {
            if part.offset > 0 { var dash = AttributedString("-"); dash.foregroundColor = Ink.muted; a += dash }
            var p = AttributedString(String(part.element))
            p.foregroundColor = part.element.first?.isUppercase == true ? Ink.amber : Ink.text
            a += p
        }
        return a
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var sync: Sync
    @State private var importing = false
    @State private var importResult: DashlaneImport.Result?
    @State private var error: String?
    @State private var changing = false
    @State private var confirmErase = false
    @State private var bio = false
    @State private var lockAfter = VaultStore.autoLockSeconds

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow("Settings")
                    Eyebrow("Security").padding(.top, 12)
                    Panel {
                        VStack(spacing: 0) {
                            if VaultCrypto.biometryAvailable {
                                InkToggle(isOn: $bio, label: "Unlock with \(VaultCrypto.biometryName())").padding(.horizontal, 16).frame(minHeight: 56)
                                Hairline()
                            }
                            HStack {
                                Text("Lock after").font(.plex(16)).foregroundStyle(Ink.text)
                                Spacer()
                                Picker("Lock after", selection: $lockAfter) {
                                    Text("Right away").tag(0); Text("1 minute").tag(60); Text("5 minutes").tag(300); Text("15 minutes").tag(900); Text("1 hour").tag(3600)
                                }
                                .labelsHidden().tint(Ink.amber)
                            }
                            .padding(.leading, 16).padding(.trailing, 4).frame(minHeight: 56)
                            Hairline()
                            settingsButton("Change master password") { changing = true }
                            Hairline()
                            settingsButton("Lock now") { store.lock() }
                        }
                    }
                    QuickUsernamesPanel().padding(.top, 12)
                    SyncPanel(sync: sync).padding(.top, 12)
                    TransferTrace()
                    AutoFillTraceView()
                    Eyebrow("Move to Vault").padding(.top, 12)
                    Panel { settingsButton("Import Dashlane or CSV file") { importing = true } }
                    Text("Choose the .zip or .csv file Dashlane made. It is read on this iPhone only. Delete the file afterwards, since it holds your passwords unprotected.")
                        .font(.plex(13)).foregroundStyle(Ink.muted)
                    Eyebrow("AutoFill").padding(.top, 12)
                    Panel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open the Settings app, tap General, then AutoFill & Passwords, and turn on Vault.").font(.plex(15)).foregroundStyle(Ink.text)
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                Link(destination: url) { Text("OPEN SETTINGS").font(.mono(12, .medium)).tracking(1).foregroundStyle(Ink.amber) }
                                    .frame(minHeight: 44)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    }
                    Eyebrow("About").padding(.top, 12)
                    Panel {
                        VStack(spacing: 0) {
                            info("Items", "\(store.items.count)"); Hairline()
                            info("Encryption", "AES-256-GCM"); Hairline()
                            info("Key storage", "Secure Enclave"); Hairline()
                            info("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                        }
                    }
                    if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red) }
                    Button("Erase vault from this iPhone") { confirmErase = true }
                        .buttonStyle(InkButtonStyle(kind: .destructive)).padding(.top, 12)
                }
                .padding(16)
            }
            .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { bio = store.hasBiometrics; lockAfter = VaultStore.autoLockSeconds }
            .onChange(of: bio) { _, v in
                guard v != store.hasBiometrics else { return }
                do { try store.setBiometrics(v) } catch { self.error = error.localizedDescription; bio = store.hasBiometrics }
            }
            .onChange(of: lockAfter) { _, v in store.setAutoLock(v) }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip, .commaSeparatedText, .json, .plainText]) { res in
                switch res {
                case .success(let url):
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    do { importResult = try DashlaneImport.read(data: Data(contentsOf: url), filename: url.lastPathComponent); error = nil }
                    catch { self.error = error.localizedDescription }
                case .failure(let e): error = e.localizedDescription
                }
            }
            .sheet(item: $importResult) { r in
                NavigationStack { ImportReview(result: r) { importResult = nil } }
            }
            .sheet(isPresented: $changing) { NavigationStack { ChangeMasterView() } }
            .confirmationDialog("Erase every item from this iPhone? This cannot be undone.", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase vault", role: .destructive) { store.eraseEverything() }
            }
        }
    }

    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title).font(.plex(16)).foregroundStyle(Ink.text); Spacer(); Text("›").foregroundStyle(Ink.muted) }
                .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack { Text(k).font(.plex(16)).foregroundStyle(Ink.text); Spacer(); Text(v).font(.mono(14)).foregroundStyle(Ink.muted) }
            .padding(.horizontal, 16).frame(minHeight: 52)
    }
}


struct ImportReview: View {
    @EnvironmentObject var store: VaultStore
    let result: DashlaneImport.Result
    var done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Move from Dashlane")
                Text("\(result.items.count) items ready to move").font(.plex(24, .semibold)).foregroundStyle(Ink.text)
                Text("Read on this iPhone only from \(result.files.joined(separator: ", ")).").font(.plex(14)).foregroundStyle(Ink.mid)
                Panel {
                    VStack(spacing: 0) {
                        line("Logins", result.count(.login)); Hairline()
                        line("One-time codes, inside logins", result.otpCount); Hairline()
                        line("Secure notes", result.count(.note)); Hairline()
                        line("Cards and bank accounts", result.count(.card) + result.count(.bank)); Hairline()
                        line("IDs and personal info", result.count(.identity) + result.count(.personal))
                    }
                }
                if !result.passkeySites.isEmpty {
                    Text("\(result.passkeySites.count) sites used a passkey that a file cannot carry. Set them up again: \(result.passkeySites.joined(separator: ", ")).")
                        .font(.plex(13)).foregroundStyle(Ink.amber)
                }
                HStack(spacing: 8) {
                    Button("Cancel", action: done).buttonStyle(InkButtonStyle(kind: .secondary))
                    Button("Move \(result.items.count) items") { store.add(result.items); done() }.buttonStyle(InkButtonStyle(kind: .primary))
                }
                .padding(.top, 12)
            }
            .padding(16)
        }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
    }

    private func line(_ k: String, _ n: Int) -> some View {
        HStack { Text(k).font(.plex(15)).foregroundStyle(Ink.text); Spacer(); Text("\(n)").font(.mono(15, .medium)).foregroundStyle(Ink.text) }
            .padding(.horizontal, 16).frame(minHeight: 46)
    }
}

struct ChangeMasterView: View {
    @EnvironmentObject var store: VaultStore
    @Environment(\.dismiss) var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Panel {
                    VStack(spacing: 0) {
                        InkField(label: "Current master password", text: $current, secure: true); Hairline()
                        InkField(label: "New master password", text: $new, secure: true); Hairline()
                        InkField(label: "Type it again", text: $confirm, secure: true)
                    }
                }
                if let error { Text(error).font(.plex(14)).foregroundStyle(Ink.red) }
                Button("Save new password") {
                    do { try store.changeMaster(current: current, new: new); dismiss() } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(InkButtonStyle(kind: .primary)).disabled(new.count < 12 || new != confirm || current.isEmpty)
            }
            .padding(16)
        }
        .background(Ink.bg.ignoresSafeArea())
            .dismissesKeyboard()
        .navigationTitle("MASTER PASSWORD").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { CapsButton("Cancel", color: Ink.mid) { dismiss() } } }
    }
}
