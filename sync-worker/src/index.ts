// Vault sync: stores scrambled vault blobs only. The server never sees a password or a key.
//   GET  /vault-sync/v/:id/envelope   -> locked key envelope (needed to join a new device with the master password)
//   GET  /vault-sync/v/:id            -> { version, payload } (Bearer token required)
//   PUT  /vault-sync/v/:id            -> body { version, payload, envelope, tokenHash? } (Bearer token required)
import { DurableObject } from "cloudflare:workers";

interface Env { VAULTS: DurableObjectNamespace<VaultBox> }

const MAX = 8 * 1024 * 1024;
const headers = { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const m = url.pathname.match(/^\/vault-sync\/v\/([a-f0-9]{32})(\/envelope)?$/);
    if (!m) return json({ error: "not found" }, 404);
    const len = Number(req.headers.get("content-length") ?? "0");
    if (len > MAX) return json({ error: "too large" }, 413);
    const stub = env.VAULTS.get(env.VAULTS.idFromName(m[1]));
    return stub.handle(req.method, !!m[2], req.headers.get("authorization") ?? "", req.method === "PUT" ? await req.text() : "");
  },
};

async function sha256(s: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function sameHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let x = 0;
  for (let i = 0; i < a.length; i++) x |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return x === 0;
}

export class VaultBox extends DurableObject<Env> {
  private sql = this.ctx.storage.sql;
  private ready = false;

  private init() {
    if (this.ready) return;
    this.sql.exec(`CREATE TABLE IF NOT EXISTS box (k INTEGER PRIMARY KEY CHECK (k = 1), token_hash TEXT NOT NULL,
      version INTEGER NOT NULL, payload TEXT NOT NULL, envelope TEXT NOT NULL, updated INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS hits (t INTEGER NOT NULL)`);
    this.ready = true;
  }

  private row() {
    const r = this.sql.exec(`SELECT token_hash, version, payload, envelope FROM box WHERE k = 1`).toArray();
    return r[0] as { token_hash: string; version: number; payload: string; envelope: string } | undefined;
  }

  // Simple brake: at most 120 requests a minute per vault.
  private limited(): boolean {
    const now = Date.now();
    this.sql.exec(`DELETE FROM hits WHERE t < ?`, now - 60_000);
    const n = (this.sql.exec(`SELECT COUNT(*) AS n FROM hits`).one() as { n: number }).n;
    if (n >= 120) return true;
    this.sql.exec(`INSERT INTO hits (t) VALUES (?)`, now);
    return false;
  }

  async handle(method: string, envelopeOnly: boolean, auth: string, body: string): Promise<Response> {
    this.init();
    if (this.limited()) return json({ error: "slow down" }, 429);
    const row = this.row();
    if (method === "GET" && envelopeOnly) return row ? json({ envelope: row.envelope }) : json({ error: "no vault" }, 404);

    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (token.length < 32) return json({ error: "unauthorized" }, 401);
    const hash = await sha256(token);

    if (method === "GET") {
      if (!row) return json({ error: "no vault" }, 404);
      if (!sameHex(hash, row.token_hash)) return json({ error: "unauthorized" }, 401);
      return json({ version: row.version, payload: row.payload });
    }
    if (method !== "PUT") return json({ error: "method" }, 405);

    let b: { version: number; payload: string; envelope: string };
    try { b = JSON.parse(body); } catch { return json({ error: "bad json" }, 400); }
    if (typeof b.payload !== "string" || typeof b.envelope !== "string" || typeof b.version !== "number") return json({ error: "bad body" }, 400);

    if (!row) {
      this.sql.exec(`INSERT INTO box (k, token_hash, version, payload, envelope, updated) VALUES (1, ?, 1, ?, ?, ?)`, hash, b.payload, b.envelope, Date.now());
      return json({ version: 1 });
    }
    if (!sameHex(hash, row.token_hash)) return json({ error: "unauthorized" }, 401);
    if (b.version !== row.version) return json({ error: "conflict", version: row.version, payload: row.payload }, 409);
    const v = row.version + 1;
    this.sql.exec(`UPDATE box SET version = ?, payload = ?, envelope = ?, updated = ? WHERE k = 1`, v, b.payload, b.envelope, Date.now());
    return json({ version: v });
  }
}
