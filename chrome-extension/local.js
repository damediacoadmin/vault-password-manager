// Vault for Chrome, iPhone-linked mode: the extension keeps its own end-to-end encrypted copy of
// the vault, synced through the same Cloudflare server the iPhone and Mac use.
//
// What is stored where:
// - chrome.storage.local (on disk): the vault ID, the SEALED vault exactly as the server has it,
//   and the locked key envelope. Nothing readable without the vault key.
// - chrome.storage.session (memory only, gone when Chrome quits): the vault key while unlocked.
// The key arrives sealed from your iPhone (scan + Face ID) or is unwrapped from your master
// password. It is never written to disk and is dropped after 30 idle minutes or when the Mac locks.

const SYNC = "https://YOUR-SYNC-HOST/vault-sync/";
const IDLE_MS = 30 * 60 * 1000;
const enc = new TextEncoder(), dec = new TextDecoder();

// ---------- bytes ----------
const b64 = (u8) => { let s = ""; for (let i = 0; i < u8.length; i += 0x8000) s += String.fromCharCode(...u8.subarray(i, i + 0x8000)); return btoa(s); };
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const b64url = (u8) => b64(u8).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const hex = (u8) => [...u8].map((b) => b.toString(16).padStart(2, "0")).join("");
const rand = (n) => crypto.getRandomValues(new Uint8Array(n));

// ---------- crypto, matching the iPhone and Mac apps ----------
async function hkdf(ikm, info, len, salt = new Uint8Array(0)) {
  const k = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: enc.encode(info) }, k, len * 8));
}
const aesKey = (raw) => crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
async function open(combined, key, aad) {   // CryptoKit "combined": 12-byte nonce, ciphertext, 16-byte tag
  return new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv: combined.subarray(0, 12), additionalData: enc.encode(aad) }, key, combined.subarray(12)));
}
async function seal(plain, key, aad) {
  const iv = rand(12);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: enc.encode(aad) }, key, plain));
  const out = new Uint8Array(12 + ct.length); out.set(iv); out.set(ct, 12); return out;
}
const vaultID = async (raw) => hex(await hkdf(raw, "vault-sync-id-v1", 16));
const authToken = async (raw) => hex(await hkdf(raw, "vault-sync-auth-v1", 32));

async function unwrapWithMaster(envelopeB64, master) {
  const env = JSON.parse(dec.decode(unb64(envelopeB64)));
  const pw = await crypto.subtle.importKey("raw", enc.encode(master.normalize("NFC")), "PBKDF2", false, ["deriveBits"]);
  const bits = new Uint8Array(await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: unb64(env.salt), iterations: env.iterations }, pw, 256));
  try { return await open(unb64(env.passwordWrap), await aesKey(bits), "pw"); } finally { bits.fill(0); }
}

// ---------- state ----------
let payload = null;      // decrypted vault, kept only in this worker's memory while unlocked
let keyRaw = null;
let link = null;         // { channel, priv, pubB64, at } while a QR code is showing

async function linked() { return (await chrome.storage.local.get("phone")).phone || null; }
async function setLinked(p) { await chrome.storage.local.set({ phone: p }); }

async function sessionKey() {
  const s = await chrome.storage.session.get(["lkey", "lastUse"]);
  if (!s.lkey) return null;
  if (Date.now() - (s.lastUse || 0) > IDLE_MS) { await lock(); return null; }
  await chrome.storage.session.set({ lastUse: Date.now() });
  return unb64(s.lkey);
}

export async function lock() {
  await chrome.storage.session.remove(["lkey", "lastUse"]);
  payload = null; keyRaw?.fill(0); keyRaw = null;
}

async function unlockWith(raw) {
  const ph = await linked();
  if (!ph || (await vaultID(raw)) !== ph.id) throw new Error("That is a different vault.");
  await chrome.storage.session.setAccessLevel?.({ accessLevel: "TRUSTED_CONTEXTS" });
  await chrome.storage.session.set({ lkey: b64(raw), lastUse: Date.now() });
  keyRaw = raw; payload = null;
  await pull(true);
}

async function ready() {
  const raw = await sessionKey();
  if (!raw) return null;
  if (!keyRaw || b64(keyRaw) !== b64(raw)) { keyRaw = raw; payload = null; }
  if (!payload) {
    const ph = await linked();
    payload = JSON.parse(dec.decode(await open(unb64(ph.sealed), await aesKey(keyRaw), "vault-v1")));
  }
  pull(false).catch(() => {});   // refresh in the background, at most every 30 seconds
  return payload;
}

// ---------- sync ----------
let lastPull = 0, pulling = null;
async function pull(force) {
  if (!force && Date.now() - lastPull < 30000) return;
  if (pulling) return pulling;
  pulling = (async () => {
    const ph = await linked();
    const r = await fetch(`${SYNC}v/${ph.id}`, { headers: { authorization: `Bearer ${await authToken(keyRaw)}` }, cache: "no-store" });
    if (r.status === 404) throw new Error("Your iPhone has not synced this vault yet. Turn on Sync in Vault on your iPhone.");
    if (!r.ok) throw new Error("Could not reach the sync server.");
    const { version, payload: sealedB64 } = await r.json();
    const remote = JSON.parse(dec.decode(await open(unb64(sealedB64), await aesKey(keyRaw), "vault-v1")));
    payload = payload ? merge(payload, remote) : remote;
    const env = await fetch(`${SYNC}v/${ph.id}/envelope`, { cache: "no-store" }).then((x) => x.ok ? x.json() : {}).catch(() => ({}));
    await setLinked({ ...ph, version, sealed: sealedB64, envelope: env.envelope || ph.envelope, syncedAt: Date.now() });
    lastPull = Date.now();
    if (!ph.seenAt || Date.now() - ph.seenAt > 6 * 3600 * 1000) await touchDevice();
  })().finally(() => { pulling = null; });
  return pulling;
}

async function push() {
  for (let i = 0; i < 3; i++) {
    const ph = await linked();
    const sealed = b64(await seal(enc.encode(JSON.stringify(payload)), await aesKey(keyRaw), "vault-v1"));
    const r = await fetch(`${SYNC}v/${ph.id}`, {
      method: "PUT", cache: "no-store",
      headers: { authorization: `Bearer ${await authToken(keyRaw)}`, "content-type": "application/json" },
      body: JSON.stringify({ version: ph.version, payload: sealed, envelope: ph.envelope }),
    });
    if (r.ok) { const { version } = await r.json(); await setLinked({ ...ph, version, sealed, syncedAt: Date.now() }); return; }
    if (r.status === 409) {
      const c = await r.json();
      payload = merge(payload, JSON.parse(dec.decode(await open(unb64(c.payload), await aesKey(keyRaw), "vault-v1"))));
      await setLinked({ ...ph, version: c.version });
      continue;
    }
    throw new Error("Could not save to the sync server.");
  }
  throw new Error("Could not save, try again.");
}

// Same rules as the apps: newest change wins per item, deletions are remembered.
function merge(a, b) {
  const out = { ...a };
  const tomb = { ...(a.deleted || {}) };
  for (const [k, v] of Object.entries(b.deleted || {})) tomb[k] = Math.max(tomb[k] ?? -Infinity, v);
  const byId = new Map();
  for (const it of [...a.items, ...b.items]) { const cur = byId.get(it.id); if (!cur || it.modified > cur.modified) byId.set(it.id, it); }
  out.items = [...byId.values()].filter((it) => !(it.id in tomb) || tomb[it.id] < it.modified).sort((x, y) => x.created - y.created);
  out.deleted = Object.keys(tomb).length ? tomb : undefined;
  if ((b.quickUsernamesChanged ?? -Infinity) > (a.quickUsernamesChanged ?? -Infinity)) { out.quickUsernames = b.quickUsernames; out.quickUsernamesChanged = b.quickUsernamesChanged; }
  const devs = new Map();
  for (const d of [...(a.devices || []), ...(b.devices || [])]) { const c = devs.get(d.id); if (!c || d.lastSeen > c.lastSeen) devs.set(d.id, d); }
  out.devices = devs.size ? [...devs.values()] : undefined;
  const logs = new Map(); for (const e of [...(a.aiLog || []), ...(b.aiLog || [])]) logs.set(e.id, e);
  out.aiLog = [...logs.values()].sort((x, y) => y.date - x.date).slice(0, 500);
  for (const k of Object.keys(out)) if (out[k] === undefined) delete out[k];
  return out;
}

async function touchDevice() {
  const ph = await linked();
  const me = { id: ph.deviceId, name: "Chrome", platform: "Chrome", lastSeen: Date.now() / 1000 };
  payload.devices = [...(payload.devices || []).filter((d) => d.id !== me.id), me];
  await push();
  await setLinked({ ...(await linked()), seenAt: Date.now() });
}

// ---------- link by QR ----------

export async function linkStart() {
  const pair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const pub = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  link = { channel: hex(rand(16)), priv: pair.privateKey, at: Date.now() };
  return { ok: true, text: `vault-link:${link.channel}.${b64url(pub)}` };
}

export async function linkPoll() {
  if (!link || Date.now() - link.at > 9 * 60 * 1000) return { ok: false, code: "expired" };
  const r = await fetch(`${SYNC}link/${link.channel}`, { cache: "no-store" }).catch(() => null);
  if (!r || r.status === 404) return { ok: false, code: "waiting" };
  if (!r.ok) return { ok: false, code: "error", error: "Could not reach the sync server." };
  const { pub, box } = await r.json();
  try {
    const phonePub = await crypto.subtle.importKey("raw", unb64(pub), { name: "ECDH", namedCurve: "P-256" }, false, []);
    const shared = new Uint8Array(await crypto.subtle.deriveBits({ name: "ECDH", public: phonePub }, link.priv, 256));
    const sym = await aesKey(await hkdf(shared, link.channel, 32, enc.encode("vault-link-v1")));
    shared.fill(0);
    const msg = JSON.parse(dec.decode(await open(unb64(box), sym, "link")));
    const raw = unb64(msg.key);
    if ((await vaultID(raw)) !== msg.id) throw new Error("bad");
    link = null;
    const ph = await linked();
    if (!ph || ph.id !== msg.id) await setLinked({ id: msg.id, deviceId: crypto.randomUUID().toUpperCase(), version: 0, sealed: "", envelope: "", from: msg.from || "iPhone" });
    await chrome.storage.local.set({ mode: "phone" });
    await unlockWith(raw);
    return { ok: true };
  } catch (e) {
    link = null;
    return { ok: false, code: "error", error: e.message === "bad" ? "That code did not check out. Try again." : e.message || "Linking failed." };
  }
}

export async function unlink() {
  await lock();
  await chrome.storage.local.remove(["phone", "mode"]);
  return { ok: true };
}

// ---------- the same requests the Mac app answers ----------

function host(raw) {
  let t = String(raw || "").trim().toLowerCase();
  if (!t) return null;
  if (!t.includes("://")) t = "https://" + t;
  let h; try { h = new URL(t).hostname; } catch { return null; }
  if (!h.includes(".")) return null;
  return h.startsWith("www.") ? h.slice(4) : h;
}
function base(h) {
  const p = h.split(".");
  if (p.length <= 2) return h;
  const two = ["co.uk", "com.au", "co.jp", "com.br", "co.nz", "org.uk", "gov.uk", "com.mx", "co.in"];
  return two.includes(p.slice(-2).join(".")) ? p.slice(-3).join(".") : p.slice(-2).join(".");
}
function matches(saved, requested) { const s = host(saved), r = host(requested); return !!s && !!r && base(s) === base(r); }
function displayName(it) {
  const t = (it.title || "").trim();
  const looksLikeHost = t && !t.includes(" ") && t.includes(".");
  if (t && !looksLikeHost) return t;
  const h = host(t) || it.urls.map(host).find(Boolean);
  if (!h) return t || it.username || "Untitled";
  if (/^[\d.]+$/.test(h)) return h;
  const first = base(h).split(".")[0];
  return first.charAt(0).toUpperCase() + first.slice(1);
}
const siteName = (h) => { const f = base(h).split(".")[0]; return f.charAt(0).toUpperCase() + f.slice(1); };
const logins = () => payload.items.filter((i) => i.kind === "login");
const loginsFor = (u) => logins().filter((i) => i.urls.some((s) => matches(s, u)));
const order = (a, b) => (a.favorite !== b.favorite ? (a.favorite ? -1 : 1) : (b.lastUsed || 0) - (a.lastUsed || 0));
const summary = (it) => ({ id: it.id, title: displayName(it), username: it.username, host: it.urls.map(host).find(Boolean) || "", totp: !!parseOTP(it.otp), favorite: !!it.favorite });

function usernameSuggestions(limit = 8) {
  const out = (payload.quickUsernames || []).filter(Boolean);
  const count = new Map();
  for (const it of logins()) if (it.username) count.set(it.username, (count.get(it.username) || 0) + 1);
  for (const [u] of [...count].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))) if (!out.includes(u)) out.push(u);
  return out.slice(0, limit);
}

export async function command(cmd, req) {
  const ph = await linked();
  if (!ph) return { ok: false, code: "unpaired", error: "Link Chrome to your vault first." };
  if (cmd === "lock") { await lock(); return { ok: true, state: "locked" }; }
  if (cmd === "generate") return { ok: true, password: await generate(req) };
  if (cmd === "unlock") {
    if (!req.master) return { ok: false, code: "locked" };
    try {
      let env = ph.envelope;
      if (!env) env = (await fetch(`${SYNC}v/${ph.id}/envelope`, { cache: "no-store" }).then((r) => r.json())).envelope;
      await unlockWith(await unwrapWithMaster(env, req.master));
      return { ok: true, state: "unlocked" };
    } catch (e) { return { ok: false, code: "wrong", error: /different|sync|iPhone/.test(e.message) ? e.message : "Wrong master password." }; }
  }
  let p;
  try { p = await ready(); } catch (e) { return { ok: false, code: "error", error: e.message }; }
  if (cmd === "status") return { ok: true, state: p ? "unlocked" : "locked", mode: "phone", from: ph.from || "iPhone", syncedAt: ph.syncedAt || 0 };
  if (!p) return { ok: false, code: "locked", error: "Vault is locked in Chrome." };
  const url = req.url || "";

  switch (cmd) {
    case "logins": {
      const h = host(url);
      if (!h) return { ok: true, host: "", logins: [], usernames: usernameSuggestions() };
      return { ok: true, host: h, logins: loginsFor(h).sort(order).map(summary), usernames: usernameSuggestions() };
    }
    case "search": {
      const q = String(req.q || "").toLowerCase().trim();
      const hits = q ? logins().filter((i) => [displayName(i), i.title, i.username, ...i.urls].some((s) => String(s).toLowerCase().includes(q))) : logins().filter((i) => i.favorite);
      return { ok: true, logins: hits.sort(order).slice(0, 40).map(summary) };
    }
    case "fill": {
      const it = p.items.find((i) => i.id === req.id);
      if (!it) return { ok: false, error: "That login is gone." };
      if (!it.urls.some((s) => matches(s, url))) {
        // A login saved for a different site: ask for the master password first (phishing guard).
        if (!req.master) return { ok: false, code: "confirm", error: "Enter your master password to use this login here." };
        try { const raw = await unwrapWithMaster(ph.envelope, req.master); if (b64(raw) !== b64(keyRaw)) throw 0; }
        catch { return { ok: false, code: "denied", error: "Wrong master password." }; }
      }
      const out = { ok: true, username: it.username, password: it.password };
      const t = parseOTP(it.otp); if (t) Object.assign(out, await totp(t));
      return out;
    }
    case "code": {
      const it = p.items.find((i) => i.id === req.id), t = it && parseOTP(it.otp);
      if (!t) return { ok: false, error: "No 2FA code saved for this login." };
      return { ok: true, ...(await totp(t)) };
    }
    case "check": {
      const h = host(url), user = req.username || "", pw = req.password || "";
      if (!h || !pw) return { ok: true, status: "skip" };
      const same = loginsFor(h).filter((i) => i.username.toLowerCase() === user.toLowerCase());
      if (same.some((i) => i.password === pw)) return { ok: true, status: "same" };
      if (same[0]) return { ok: true, status: "update", id: same[0].id, title: displayName(same[0]) };
      return { ok: true, status: "new", title: siteName(h) };
    }
    case "save": {
      const h = host(url), now = Date.now() / 1000, pw = req.password || "";
      if (!h || !pw) return { ok: false, error: "Nothing to save." };
      let it = req.id && p.items.find((i) => i.id === req.id);
      if (it) {
        if (!it.urls.some((s) => matches(s, h))) return { ok: false, error: "That login belongs to another site." };
        if (it.password !== pw) { it.history = [{ password: it.password, changed: it.passwordChanged }, ...(it.history || [])]; it.password = pw; it.passwordChanged = now; }
        it.modified = now;
      } else {
        it = { id: crypto.randomUUID().toUpperCase(), kind: "login", title: String(req.title || siteName(h)).trim().slice(0, 80) || siteName(h),
          username: String(req.username || "").slice(0, 200), password: pw.slice(0, 500), urls: [`https://${h}`], otp: "", notes: "", fields: [],
          collection: "", favorite: false, aiAllowed: true, created: now, modified: now, passwordChanged: now, lastUsed: now, history: [] };
        p.items.push(it);
      }
      try { await push(); } catch (e) { return { ok: false, error: e.message }; }
      return { ok: true, id: it.id };
    }
  }
  return { ok: false, error: "Unknown request." };
}

// ---------- 2FA codes ----------
function base32(s) {
  const A = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"; let bits = 0, n = 0; const out = [];
  for (const c of s.toUpperCase()) { if ("= -".includes(c)) continue; const v = A.indexOf(c); if (v < 0) return null; bits = (bits << 5) | v; n += 5; if (n >= 8) { out.push((bits >>> (n - 8)) & 255); n -= 8; } }
  return new Uint8Array(out);
}
function parseOTP(raw) {
  const s = String(raw || "").trim(); if (!s) return null;
  let secret, digits = 6, period = 30, alg = "SHA-1";
  if (s.toLowerCase().startsWith("otpauth://")) {
    let u; try { u = new URL(s); } catch { return null; }
    const q = Object.fromEntries([...u.searchParams].map(([k, v]) => [k.toLowerCase(), v]));
    secret = q.secret && base32(q.secret);
    const d = parseInt(q.digits); if (d >= 6 && d <= 8) digits = d;
    const p = parseInt(q.period); if (p > 0) period = p;
    alg = { SHA1: "SHA-1", SHA256: "SHA-256", SHA512: "SHA-512" }[(q.algorithm || "SHA1").toUpperCase()] || "SHA-1";
  } else secret = base32(s);
  return secret && secret.length ? { secret, digits, period, alg } : null;
}
async function totp(t) {
  const now = Math.floor(Date.now() / 1000), ctr = Math.floor(now / t.period);
  const msg = new Uint8Array(8); new DataView(msg.buffer).setUint32(0, Math.floor(ctr / 2 ** 32)); new DataView(msg.buffer).setUint32(4, ctr >>> 0);
  const k = await crypto.subtle.importKey("raw", t.secret, { name: "HMAC", hash: t.alg }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", k, msg));
  const o = mac[mac.length - 1] & 15;
  const bin = ((mac[o] & 127) << 24) | (mac[o + 1] << 16) | (mac[o + 2] << 8) | mac[o + 3];
  return { code: String(bin % 10 ** t.digits).padStart(t.digits, "0"), seconds: t.period - (now % t.period) };
}

// ---------- password generator (same rules as the apps) ----------
let words = null;
const uniform = (n) => { const lim = 2 ** 32 - (2 ** 32 % n); for (;;) { const v = crypto.getRandomValues(new Uint32Array(1))[0]; if (v < lim) return v % n; } };
async function generate(o) {
  const style = o.style === "Words" ? "Words" : "Characters", symbols = o.symbols !== "0", digits = o.digits !== "0";
  if (style === "Words") {
    words ||= (await (await fetch(chrome.runtime.getURL("wordlist.txt"))).text()).split(/\r?\n/).filter(Boolean);
    const n = Math.min(10, Math.max(3, parseInt(o.words) || 5));
    const parts = Array.from({ length: n }, () => words[uniform(words.length)]);
    let any = false;
    parts.forEach((w, i) => { if (uniform(2)) { parts[i] = w[0].toUpperCase() + w.slice(1); any = true; } });
    if (!any) { const i = uniform(n); parts[i] = parts[i][0].toUpperCase() + parts[i].slice(1); }
    if (digits) parts.splice(1 + uniform(parts.length - 1), 0, String(uniform(10)));
    let out = parts.join("-");
    if (symbols) out += "!#$%&*+=?@"[uniform(10)];
    return out;
  }
  const pools = ["abcdefghijkmnopqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ"];
  if (digits) pools.push("23456789");
  if (symbols) pools.push("!#$%&*+-=?@^_");
  const all = pools.join(""), n = Math.min(64, Math.max(8, parseInt(o.length) || 20));
  const chars = pools.map((p) => p[uniform(p.length)]);
  while (chars.length < n) chars.push(all[uniform(all.length)]);
  for (let i = chars.length - 1; i > 0; i--) { const j = uniform(i + 1); [chars[i], chars[j]] = [chars[j], chars[i]]; }
  return chars.join("");
}
