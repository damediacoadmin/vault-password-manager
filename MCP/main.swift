import Foundation

// vault-mcp: a tiny MCP server (stdio, JSON-RPC 2.0) that lets an AI assistant ask the Vault Mac
// app for ONE login by website. It holds no secrets itself. Every request is approved in Vault
// with a click and Touch ID. There is deliberately no tool to list, search or export the vault.

setvbuf(stdout, nil, _IOLBF, 0)
var clientName = "AI assistant"

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
    print(s)
}

func reply(_ id: Any, _ result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func fail(_ id: Any, _ code: Int, _ msg: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]]) }

let tool: [String: Any] = [
    "name": "get_login",
    "description": "Ask the user's Vault password manager for the username and password saved for one website. The user must approve each request on their Mac with Touch ID, so it can take up to two minutes. Use only when you need to sign in somewhere for the user. Never repeat the password back in chat.",
    "inputSchema": [
        "type": "object",
        "properties": [
            "site": ["type": "string", "description": "The website, for example github.com"],
            "reason": ["type": "string", "description": "One short sentence the user will see explaining why you need it"]
        ],
        "required": ["site", "reason"]
    ],
    "annotations": ["readOnlyHint": true, "openWorldHint": false]
]

func askVault(site: String, reason: String) -> [String: Any] {
    var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Vault")
    #if DEBUG
    if ProcessInfo.processInfo.environment["VAULT_TEST_MODE"] == "1" { dir = dir.appendingPathComponent("Test") }   // throwaway test vault
    #endif
    let path = dir.appendingPathComponent("ai.sock").path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return ["ok": false, "error": "Could not open a connection."] }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { p in for (i, b) in bytes.enumerated() where i < p.count - 1 { p[i] = b } }
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard ok == 0 else { return ["ok": false, "error": "Vault is not running on this Mac. Ask the user to open Vault."] }
    let req: [String: String] = ["site": site, "reason": reason, "client": clientName]
    guard var d = try? JSONSerialization.data(withJSONObject: req) else { return ["ok": false, "error": "Bad request."] }
    d.append(0x0A)
    _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
    var buf = [UInt8](repeating: 0, count: 4096)
    var out = Data()
    while !out.contains(0x0A) {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    guard let line = out.split(separator: 0x0A).first,
          let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
        return ["ok": false, "error": "No answer from Vault."]
    }
    return obj
}

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    let method = msg["method"] as? String ?? ""
    guard let id = msg["id"] else { continue }   // notifications need no answer
    switch method {
    case "initialize":
        if let p = msg["params"] as? [String: Any], let info = p["clientInfo"] as? [String: Any], let n = info["name"] as? String {
            clientName = n.lowercased().contains("code") ? "Claude Code" : n.lowercased().contains("claude") ? "Claude app" : n
        }
        let requested = (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
        reply(id, ["protocolVersion": requested,
                   "capabilities": ["tools": ["listChanged": false]],
                   "serverInfo": ["name": "vault", "version": "1.0"],
                   "instructions": "Use get_login only when you must sign in for the user. Each call waits for the user's Touch ID approval on their Mac."])
    case "ping":
        reply(id, [:])
    case "tools/list":
        reply(id, ["tools": [tool]])
    case "tools/call":
        let p = msg["params"] as? [String: Any] ?? [:]
        guard (p["name"] as? String) == "get_login" else { fail(id, -32602, "Unknown tool"); continue }
        let args = p["arguments"] as? [String: Any] ?? [:]
        let site = (args["site"] as? String) ?? ""
        let reason = (args["reason"] as? String) ?? ""
        let r = askVault(site: site, reason: reason)
        if (r["ok"] as? Bool) == true {
            var text = "Site: \(r["site"] ?? site)\nUsername: \(r["username"] ?? "")\nPassword: \(r["password"] ?? "")"
            if let code = r["one_time_code"] { text += "\nOne-time code (valid about 30 seconds): \(code)" }
            reply(id, ["content": [["type": "text", "text": text]], "isError": false])
        } else {
            reply(id, ["content": [["type": "text", "text": (r["error"] as? String) ?? "Vault did not share this login."]], "isError": true])
        }
    default:
        fail(id, -32601, "Method not found")
    }
}
