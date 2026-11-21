#if DEBUG
import Foundation

/// Debug builds only: `-demo` fills a throwaway vault with made-up items for screenshots.
enum DemoSeed {
    @MainActor static func runIfRequested(_ store: VaultStore) {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-demo") else { return }
        store.eraseEverything()
        _ = try? store.create(master: "demo-only-not-real-0", useBiometrics: false)
        store.finishSetup()
        let old = Date().addingTimeInterval(-3 * 365 * 86_400)
        var items: [VaultItem] = [
            VaultItem(title: "GitHub", username: "damedia-admin", password: "harbor-Tangle-7-velvet-Orbit", urls: ["github.com"], otp: "JBSWY3DPEHPK3PXP", collection: "Work", lastUsed: Date()),
            VaultItem(title: "Cloudflare", username: "dave@example.com", password: "quartz-Ember-3-saddle-river", urls: ["cloudflare.com"], otp: "KRSXG5CTMVRXEZLU", collection: "Work", lastUsed: Date().addingTimeInterval(-600)),
            VaultItem(title: "Stripe", username: "billing@example.com", password: "Summer2019!", urls: ["stripe.com"], collection: "Work", lastUsed: Date().addingTimeInterval(-3600)),
            VaultItem(title: "Old forum", username: "dave", password: "Summer2019!", urls: ["forum.example.org"], passwordChanged: old),
            VaultItem(title: "Utility bill", username: "dmiller", password: "password1", urls: ["utility.example.com"], passwordChanged: old),
            VaultItem(title: "Google Workspace", username: "dave@example.com", password: "maple-Pilot-9-dune-Falcon", urls: ["google.com"])
        ]
        items.append(VaultItem(title: "accounts.google.com", username: "dave@example.com", password: "Summer2019!", urls: ["https://accounts.google.com"], favorite: true))
        items.append(VaultItem(title: "google.com", username: "other@example.com", password: "orbit-Lamp-4-tide-Quill", urls: ["https://myaccount.google.com"], favorite: true))
        items.append(VaultItem(title: "0.1", username: "admin", password: "admin", urls: ["10.0.0.1"]))
        items.append(VaultItem(kind: .card, title: "Visa Business", fields: [.init(label: "Number", value: "4111111111114021", secret: true), .init(label: "Expires", value: "04/29")], lastUsed: Date().addingTimeInterval(-7200)))
        items.append(VaultItem(kind: .note, title: "Wi-Fi at the office", notes: "Network: Studio\nPassword: in the drawer"))
        store.add(items)
    }
}
#endif
