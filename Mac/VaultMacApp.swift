import SwiftUI
import AppKit
import CoreText

@main
struct VaultMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Vault", id: "main") {
            MacRoot()
                .environmentObject(delegate.store)
                .environmentObject(delegate.ai)
                .environmentObject(delegate.browser)
                .environmentObject(delegate.sync)
                .onChange(of: delegate.store.state) { _, s in if s == .unlocked { CredentialIdentities.sync(delegate.store.items); Task { await delegate.sync.syncNow() } } }
                .frame(minWidth: 860, minHeight: 560)
                .preferredColorScheme(.dark)
                .receivesCredentialExchange()
                .tint(Ink.amber)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Lock Vault") { delegate.store.lock() }.keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: .constant(!TestMode.isOn)) {
            MenuBarContent().environmentObject(delegate.store).environmentObject(delegate.ai)
        } label: {
            Image(systemName: delegate.store.state == .unlocked ? "lock.open" : "lock")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = VaultStore()
    lazy var ai = AIBroker(store: store)
    lazy var browser = BrowserBroker(store: store)
    lazy var sync = Sync(store: store)
    private var idleTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Fonts.register()
        #if DEBUG
        TestSeed.run(store)
        #endif
        store.onChange = { CredentialIdentities.sync($0.items) }
        if !TestMode.isOn { ai.start() }
        browser.start()
        _ = sync
        // Auto-lock when the whole Mac has had no keyboard or mouse use for the chosen time
        // (working in other apps counts as activity), and always on sleep or screen lock.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.state == .unlocked else { return }
                let limit = MacLock.seconds
                guard limit > 0 else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                if idle > Double(limit) { self.store.lock() }
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.store.lock() } }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.lock() }
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        ExchangeInbox.shared.receive(userActivity)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { ai.stop(); browser.stop(); store.lock() }
}

/// Mac auto-lock setting, separate from the iPhone's. 0 = only on sleep or screen lock.
enum MacLock {
    static var seconds: Int {
        get { UserDefaults.standard.object(forKey: "macAutoLockSeconds") as? Int ?? 900 }
        set { UserDefaults.standard.set(newValue, forKey: "macAutoLockSeconds") }
    }
}

enum Fonts {
    static func register() {
        for name in ["IBMPlexSans", "IBMPlexMono-Regular", "IBMPlexMono-Medium"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

enum Clipboard {
    private static var lastChange = 0
    /// Copies, then clears the clipboard after 60 seconds if nothing else was copied since.
    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        lastChange = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if NSPasteboard.general.changeCount == lastChange { NSPasteboard.general.clearContents() }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: VaultStore
    @EnvironmentObject var ai: AIBroker
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Button("Open Vault") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        if store.state == .unlocked { Button("Lock Vault") { store.lock() } }
        Divider()
        Toggle("Claude access", isOn: Binding(get: { ai.enabled }, set: { ai.setEnabled($0) }))
        ForEach(ai.activeGrants, id: \.host) { g in
            Button("Revoke \(g.host) (\(g.minutesLeft) min left)") { ai.revoke(g.host) }
        }
        Divider()
        Button("Quit Vault") { NSApp.terminate(nil) }
    }
}
