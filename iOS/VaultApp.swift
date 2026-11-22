import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Blocks third-party keyboards everywhere in Vault, so a keyboard app can never see what you type.
final class VaultAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, shouldAllowExtensionPointIdentifier id: UIApplication.ExtensionPointIdentifier) -> Bool {
        id != .keyboard
    }
}

@main
struct VaultApp: App {
    @UIApplicationDelegateAdaptor(VaultAppDelegate.self) var appDelegate
    @StateObject private var store: VaultStore
    @StateObject private var sync: Sync
    @Environment(\.scenePhase) private var phase
    @State private var backgroundedAt: Date?
    @State private var cover = false

    init() {
        InkAppearance.apply()
        UIScrollView.appearance().keyboardDismissMode = .interactive
        let s = VaultStore()
        _store = StateObject(wrappedValue: s)
        _sync = StateObject(wrappedValue: Sync(store: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(sync)
                .onChange(of: store.state) { _, s in if s == .unlocked { CredentialIdentities.sync(store.items); Task { await sync.syncNow() } } }
                .tint(Ink.amber)
                .preferredColorScheme(.dark)
                .receivesCredentialExchange()
                .overlay { if cover { PrivacyCover() } }
                .onAppear {
                    #if DEBUG
                    DemoSeed.runIfRequested(store)
                    #endif
                    store.onChange = { CredentialIdentities.sync($0.items) }
                    DispatchQueue.main.async { KeyboardSwipe.shared.installOnAllWindows() }
                }
                // Lock the moment the iPhone itself locks, whatever the auto-lock setting.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                    store.lock()
                }
        }
        .onChange(of: phase) { _, new in
            switch new {
            case .background:
                backgroundedAt = Date()
                cover = true
            case .inactive:
                cover = true
            case .active:
                cover = false
                KeyboardSwipe.shared.installOnAllWindows()
                if let t = backgroundedAt, store.state == .unlocked,
                   Date().timeIntervalSince(t) >= Double(VaultStore.autoLockSeconds) {
                    store.lock()
                }
                backgroundedAt = nil
                store.reloadState()
            @unknown default: break
            }
        }
    }
}

/// UIKit bars in the Instrument look.
enum InkAppearance {
    static func apply() {
        let mono = UIFont(name: "IBMPlexMono-Medium", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Ink.bg)
        tab.shadowColor = UIColor(Ink.line)
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.titleTextAttributes = [.font: mono, .foregroundColor: UIColor(Ink.muted), .kern: 1]
            item.normal.iconColor = UIColor(Ink.muted)
            item.selected.titleTextAttributes = [.font: mono, .foregroundColor: UIColor(Ink.amber), .kern: 1]
            item.selected.iconColor = UIColor(Ink.amber)
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Ink.bg)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.font: mono, .foregroundColor: UIColor(Ink.muted), .kern: 1.2]
        nav.largeTitleTextAttributes = [.font: UIFont(name: "IBMPlexSans-SemiBold", size: 34) ?? .systemFont(ofSize: 34, weight: .semibold),
                                        .foregroundColor: UIColor(Ink.text)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }
}

/// Hides the vault in the app switcher.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Ink.bg.ignoresSafeArea()
            Eyebrow("Vault · locked")
        }
    }
}

enum Clipboard {
    /// Copies to this device only and clears after 60 seconds.
    static func copy(_ s: String) {
        UIPasteboard.general.setItems([[UTType.plainText.identifier: s]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(60)])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Search field in the Instrument look.
struct InkSearch: View {
    @Binding var text: String
    var prompt: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Ink.muted).font(.system(size: 15))
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Ink.muted))
                .font(.plex(16)).foregroundStyle(Ink.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.muted) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).frame(height: 48)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Ink.line))
    }
}

/// Text field in a panel row with an eyebrow label.
struct InkField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var mono = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(label)
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text, axis: .vertical) }
            }
            .font(mono ? .mono(16) : .plex(16))
            .foregroundStyle(Ink.text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

/// Swipe down anywhere, tap Done above the keyboard, or scroll to put the keyboard away.
struct KeyboardDismissal: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { v in
                if v.translation.height > 40 && abs(v.translation.width) < v.translation.height { hideKeyboard() }
            })
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { hideKeyboard() }.font(.plex(16, .semibold)).foregroundStyle(Ink.amber)
                }
            }
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    func dismissesKeyboard() -> some View { modifier(KeyboardDismissal()) }
}

extension KeyboardSwipe {
    /// Adds it to every window of the app (call when the app becomes active).
    func installOnAllWindows() {
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach { install(on: $0) }
        }
    }

}
