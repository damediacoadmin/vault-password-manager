#!/usr/bin/env python3
"""End-to-end test of the AI agent connection (vault-mcp -> Vault Mac app), using a throwaway
test vault (Debug build, VAULT_TEST_MODE=1). Never touches the real vault.

Run from the repo root after a Debug build of the VaultMac scheme into build/dd."""
import json, os, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROD = os.path.join(ROOT, "build/dd/Build/Products/Debug/Vault.app/Contents/MacOS")
APP, MCP = os.path.join(PROD, "Vault"), os.path.join(PROD, "vault-mcp")
SOCK = os.path.expanduser("~/Library/Application Support/Vault/Test/ai.sock")
results = []

def check(name, ok, extra=""):
    results.append(("PASS" if ok else "FAIL") + "  " + name + (f"  ({extra})" if extra else ""))

def start_app(**env):
    try: os.unlink(SOCK)
    except FileNotFoundError: pass
    e = dict(os.environ, VAULT_TEST_MODE="1", **env)
    p = subprocess.Popen([APP], env=e, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        if os.path.exists(SOCK): break
        time.sleep(0.25)
    time.sleep(0.5)
    return p

class Agent:
    """Talks MCP (JSON-RPC over stdio) to vault-mcp, like Claude Code does."""
    def __init__(self, client="claude-code"):
        self.p = subprocess.Popen([MCP], env=dict(os.environ, VAULT_TEST_MODE="1"), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.n = 0
        self.init = self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": client, "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); self.p.stdin.flush()
    def call(self, method, params=None):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params or {}}) + "\n"); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def login(self, site, reason="Test sign-in"):
        r = self.call("tools/call", {"name": "get_login", "arguments": {"site": site, "reason": reason}})["result"]
        return r["isError"], r["content"][0]["text"]
    def close(self): self.p.kill()

# 1. Allowed once
app = start_app(VAULT_TEST_APPROVE="1", VAULT_TEST_AI_ANSWER="once")
a = Agent()
check("agent connects (MCP initialize)", a.init.get("result", {}).get("serverInfo", {}).get("name") == "vault")
tools = a.call("tools/list")["result"]["tools"]
check("exactly one tool: get_login, no list or export", [t["name"] for t in tools] == ["get_login"])
err, text = a.login("https://login.example.test/signin")
check("approved request returns the login", not err and "Password: harbor-Tangle-7-velvet-Orbit" in text and "One-time code" in text)
err, text = a.login("nowhere.test")
check("unknown site gives a clear 'no login' answer", err and "No login saved" in text, text)
err, text = a.login("bank.test")
check("login marked 'never share with AI' is refused", err and "never be shared" in text, text)
err, text = a.login("not a site")
check("garbage site name rejected", err, text)
a.close()

# 2. Owner says no
app.kill(); app.wait()
app = start_app(VAULT_TEST_APPROVE="1", VAULT_TEST_AI_ANSWER="deny")
a = Agent()
err, text = a.login("example.test")
check("owner says no -> nothing shared", err and "said no" in text and "Password" not in text, text)
a.close()

# 3. Touch ID fails
app.kill(); app.wait()
app = start_app(VAULT_TEST_APPROVE="0", VAULT_TEST_AI_ANSWER="once")
a = Agent()
err, text = a.login("example.test")
check("Touch ID not confirmed -> nothing shared", err and "Touch ID" in text and "Password" not in text, text)
a.close()

# 4. 15-minute window, then the hourly cap
app.kill(); app.wait()
app = start_app(VAULT_TEST_APPROVE="1", VAULT_TEST_AI_ANSWER="window")
a = Agent()
oks = [a.login("example.test")[0] is False for _ in range(10)]
check("'allow for 15 minutes' covers repeat requests", all(oks), f"{sum(oks)}/10")
err, text = a.login("example.test")
check("11th request in an hour pauses AI access", err and "Too many requests" in text, text)
err, text = a.login("other.test")
check("access stays off after the pause", err and "turned off" in text, text)
a.close()

# 5. Only the signed helper may connect to the socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(SOCK); s.sendall(b'{"site":"example.test","reason":"x"}\n')
reply = s.recv(4096).decode(); s.close()
check("unsigned process talking to the socket is refused", "Only the signed Vault helper" in reply and "Password" not in reply)
check("socket is private to this user (0600)", oct(os.stat(SOCK).st_mode & 0o777) == "0o600")
app.kill(); app.wait()

subprocess.run([APP], env=dict(os.environ, VAULT_TEST_MODE="1", VAULT_TEST_CLEANUP="1"))
print("\n".join(results))
sys.exit(0 if all(r.startswith("PASS") for r in results) else 1)
