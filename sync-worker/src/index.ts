// Vault sync: stores scrambled vault blobs only. The server never sees a password or a key.
//   GET  /vault-sync/v/:id/envelope   -> locked key envelope (needed to join a new device with the master password)
//   GET  /vault-sync/v/:id            -> { version, payload } (Bearer token required)
//   PUT  /vault-sync/v/:id            -> body { version, payload, envelope, tokenHash? } (Bearer token required)
//   PUT  /vault-sync/link/:channel    -> one sealed hand-off from the iPhone to a browser being linked (max 4 KB, 10 min)
//   GET  /vault-sync/link/:channel    -> returns that hand-off once, then deletes it (404 until it arrives)
// The link hand-off is sealed to a key that only the waiting browser holds, so the server cannot read it.
import { DurableObject } from "cloudflare:workers";

interface Env { VAULTS: DurableObjectNamespace<VaultBox> }

const MAX = 8 * 1024 * 1024;
const headers = { "content-type": "application/json", "cache-control": "no-store", "x-content-type-options": "nosniff" };
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers });

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const l = url.pathname.match(/^\/vault-sync\/link\/([a-f0-9]{32})$/);
    if (l) {
      if (Number(req.headers.get("content-length") ?? "0") > 4096) return json({ error: "too large" }, 413);
      const box = env.VAULTS.get(env.VAULTS.idFromName("link:" + l[1]));
      return box.link(req.method, req.method === "PUT" ? (await req.text()).slice(0, 4096) : "");
    }
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

  // One-time hand-off box used to link a new browser. Written once, read once, gone after 10 minutes.
  async link(method: string, body: string): Promise<Response> {
    this.sql.exec(`CREATE TABLE IF NOT EXISTS link (k INTEGER PRIMARY KEY CHECK (k = 1), body TEXT NOT NULL, expires INTEGER NOT NULL)`);
    this.sql.exec(`CREATE TABLE IF NOT EXISTS hits (t INTEGER NOT NULL)`);
    if (this.limited()) return json({ error: "slow down" }, 429);
    this.sql.exec(`DELETE FROM link WHERE expires < ?`, Date.now());
    if (method === "PUT") {
      let b: { pub?: unknown; box?: unknown };
      try { b = JSON.parse(body); } catch { return json({ error: "bad json" }, 400); }
      if (typeof b.pub !== "string" || typeof b.box !== "string") return json({ error: "bad body" }, 400);
      const taken = this.sql.exec(`SELECT k FROM link WHERE k = 1`).toArray().length > 0;
      if (taken) return json({ error: "already used" }, 409);
      this.sql.exec(`INSERT INTO link (k, body, expires) VALUES (1, ?, ?)`, JSON.stringify({ pub: b.pub, box: b.box }), Date.now() + 10 * 60_000);
      return json({ ok: true });
    }
    if (method === "GET") {
      const r = this.sql.exec(`SELECT body FROM link WHERE k = 1`).toArray()[0] as { body: string } | undefined;
      if (!r) return json({ error: "waiting" }, 404);
      this.sql.exec(`DELETE FROM link WHERE k = 1`);
      return new Response(r.body, { headers });
    }
    return json({ error: "method" }, 405);
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
