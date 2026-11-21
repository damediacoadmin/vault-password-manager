import SwiftUI
import AuthenticationServices

/// Holds a Credential Exchange hand-off until the vault is unlocked.
@MainActor
final class ExchangeInbox: ObservableObject {
    static let shared = ExchangeInbox()
    @Published var token: UUID?
    @Published var result: DashlaneImport.Result?
    @Published var error: String?

    /// Last steps of a transfer, shown in Settings so a stuck hand-off can be diagnosed. Holds no secrets.
    @Published var trace: [String] = UserDefaults.standard.stringArray(forKey: "exchangeTrace") ?? []
    func note(_ s: String) {
        trace.append("\(Date().formatted(date: .omitted, time: .standard))  \(s)")
        if trace.count > 12 { trace.removeFirst(trace.count - 12) }
        UserDefaults.standard.set(trace, forKey: "exchangeTrace")
    }

    func receive(_ activity: NSUserActivity) {
        note("Hand-off received: \(activity.activityType)")
        if #available(iOS 26.0, macOS 26.0, *), let t = CredentialExchange.token(from: activity) { token = t; note("Transfer ticket found") }
        else { note("No transfer ticket in hand-off. Keys: \((activity.userInfo?.keys.map { "\($0)" } ?? []).joined(separator: ", "))") }
    }

    /// Call once the vault is unlocked.
    func fetchIfNeeded() {
        guard let t = token, result == nil else { return }
        token = nil
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        note("Asking the other app for the items")
        Task {
            do { result = try await CredentialExchange.fetch(token: t); note("Received \(result?.items.count ?? 0) items") }
            catch { self.error = "The transfer did not finish. Start it again from the other app."; note("Failed: \(error.localizedDescription)") }
        }
    }
}

extension View {
    @ViewBuilder
    func receivesCredentialExchange() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            onContinueUserActivity(ASCredentialExchangeActivity) { ExchangeInbox.shared.receive($0) }
        } else { self }
    }
}
