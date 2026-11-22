import Foundation

/// Debug-only sandbox so the Mac app can be tested end to end without touching the real vault:
/// a separate Keychain namespace, socket folder and no sync or system AutoFill updates.
/// Turned on with the VAULT_TEST_MODE=1 environment variable. Release builds ignore it.
enum TestMode {
    static let isOn: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.environment["VAULT_TEST_MODE"] == "1"
        #else
        return false
        #endif
    }()

    #if os(macOS)
    /// Folder that holds Vault's private sockets.
    static var supportDir: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vault", isDirectory: true)
        let dir = isOn ? base.appendingPathComponent("Test", isDirectory: true) : base
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
    #endif
}
