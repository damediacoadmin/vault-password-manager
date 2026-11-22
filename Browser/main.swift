import Foundation
import Security

// vault-chrome: the native messaging helper for the Vault Chrome extension.
// Chrome starts it and talks to it over stdin/stdout (4-byte length, then JSON). It holds no
// secrets. It checks that Google Chrome started it for the Vault extension, then relays each
// message to the Vault Mac app over a private socket, where pairing and every rule are enforced.

let allowedOrigins: Set<String> = ["chrome-extension://cmjgeknhijfgeipkkclkdnmblamegcpm/"]
let googleTeam = "EQHXZ8M8AV"
let outLock = NSLock()

let testMode: Bool = {
    #if DEBUG
    return ProcessInfo.processInfo.environment["VAULT_TEST_MODE"] == "1"
    #else
    return false
    #endif
}()

/// True when the process that started us is signed by Google (Chrome or one of its helpers).
func startedByChrome() -> Bool {
    let pid = getppid()
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
          let code else { return false }
    var req: SecRequirement?
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(googleTeam)\""
    guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess, let req else { return false }
    return SecCodeCheckValidity(code, [], req) == errSecSuccess
}

let origin = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("chrome-extension://") }) ?? ""
let fromChrome = allowedOrigins.contains(origin) && startedByChrome()

func readExactly(_ n: Int) -> Data? {
    var data = Data(capacity: n)
    var buf = [UInt8](repeating: 0, count: min(n, 65536))
    while data.count < n {
        let got = read(STDIN_FILENO, &buf, min(buf.count, n - data.count))
        if got <= 0 { return nil }
        data.append(contentsOf: buf[0..<got])
    }
    return data
}

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    var len = UInt32(d.count).littleEndian
    outLock.lock(); defer { outLock.unlock() }
    _ = withUnsafeBytes(of: &len) { write(STDOUT_FILENO, $0.baseAddress, 4) }
    _ = d.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, d.count) }
}

/// Opens Vault in the background when it is not running, then waits up to 6 seconds for it.
func askVault(_ req: [String: String]) -> [String: Any] {
    let first = askVaultOnce(req)
    guard first["code"] as? String == "offline", !testMode else { return first }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", "com.damediaco.vault.mac"]
    try? p.run(); p.waitUntilExit()
    for _ in 0..<12 {
        usleep(500_000)
        let r = askVaultOnce(req)
        if r["code"] as? String != "offline" { return r }
    }
    return first
}

func askVaultOnce(_ req: [String: String]) -> [String: Any] {
    let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vault")
    let path = (testMode ? home.appendingPathComponent("Test") : home).appendingPathComponent("browser.sock").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return ["ok": false, "code": "offline", "error": "Could not reach Vault."] }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() where i < p.count - 1 { p[i] = b } }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { return ["ok": false, "code": "offline", "error": "Open Vault on your Mac."] }
    guard var d = try? JSONSerialization.data(withJSONObject: req) else { return ["ok": false, "error": "Bad request."] }
    d.append(0x0A)
    _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
    d.resetBytes(in: 0..<d.count)
    var buf = [UInt8](repeating: 0, count: 8192)
    var out = Data()
    while !out.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    guard let line = out.split(separator: 0x0A).first,
          let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
        return ["ok": false, "code": "offline", "error": "No answer from Vault."]
    }
    return obj
}

while true {
    guard let head = readExactly(4) else { exit(0) }
    let len = Int(head.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian })
    guard len > 0, len < 1_048_576, let body = readExactly(len),
          let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { exit(1) }
    let rid = obj["rid"] ?? 0
    var req = obj.compactMapValues { v -> String? in
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }
    req["rid"] = nil
    req["chrome"] = (fromChrome || testMode) ? "1" : "0"
    // Each request runs on its own thread so a pairing card does not block a fill.
    Thread.detachNewThread {
        var reply = askVault(req)
        reply["rid"] = rid
        send(reply)
    }
}
