// Vault for Chrome: background worker.
// Holds no passwords. It relays requests to the Vault Mac app through the signed native helper,
// always using the page address Chrome reports for the asking frame (never one a page supplies).

import * as Local from "./local.js";

const HOST = "com.damediaco.vault";

// Two ways to reach the vault: linked to the iPhone (Chrome keeps its own encrypted copy) or
// through the Vault app on this Mac. Linking to the iPhone takes over once done.
async function mode() { return (await chrome.storage.local.get("mode")).mode || "mac"; }

chrome.idle.onStateChanged.addListener((s) => { if (s === "locked") Local.lock(); });
let port = null;
let nextId = 1;
const waiting = new Map();

function connect() {
  if (port) return port;
  port = chrome.runtime.connectNative(HOST);
  port.onMessage.addListener((msg) => {
    const done = waiting.get(msg.rid);
    if (done) { waiting.delete(msg.rid); done(msg); }
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError?.message || "";
    port = null;
    for (const [, done] of waiting) done({ ok: false, code: "nohelper", error: helperError(err) });
    waiting.clear();
  });
  return port;
}

function helperError(err) {
  if (/not found|forbidden/i.test(err)) return "Open Vault on your Mac once so Chrome can find it.";
  return "Lost the connection to Vault. Try again.";
}

async function identity() {
  let { client, key } = await chrome.storage.local.get(["client", "key"]);
  if (!client || !key) {
    client = hex(crypto.getRandomValues(new Uint8Array(16)));
    key = b64url(crypto.getRandomValues(new Uint8Array(32)));
    await chrome.storage.local.set({ client, key });
  }
  return { client, key };
}

async function vault(cmd, extra = {}, timeoutMs = 150000) {
  if ((await mode()) === "phone") return Local.command(cmd, extra);
  const id = await identity();
  return new Promise((resolve) => {
    const rid = nextId++;
    const timer = setTimeout(() => { waiting.delete(rid); resolve({ ok: false, code: "timeout", error: "Vault did not answer." }); }, timeoutMs);
    waiting.set(rid, (m) => { clearTimeout(timer); resolve(m); });
    try { connect().postMessage({ rid, cmd, client: id.client, key: id.key, ...extra }); }
    catch (e) { clearTimeout(timer); waiting.delete(rid); resolve({ ok: false, code: "nohelper", error: helperError(String(e)) }); }
  });
}

// ---------- per-tab memory (session storage, cleared when Chrome quits) ----------

const LAST_PICK_MS = 3 * 60 * 1000;
const SAVE_OFFER_MS = 90 * 1000;
// In-page menu tokens live in session storage so they survive the worker restarting.
const menus = {
  async get(t) { const k = "menu_" + t; const m = (await chrome.storage.session.get(k))[k]; return m && Date.now() - m.at < 600000 ? m : null; },
  async set(t, v) { await chrome.storage.session.set({ ["menu_" + t]: v }); },
};

async function tabMemo(tabId) {
  const k = "tab" + tabId;
  return (await chrome.storage.session.get(k))[k] || {};
}
async function setTabMemo(tabId, patch) {
  const k = "tab" + tabId;
  const cur = (await chrome.storage.session.get(k))[k] || {};
  await chrome.storage.session.set({ [k]: { ...cur, ...patch } });
}
chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove("tab" + tabId));

function baseDomain(host) {
  const parts = (host || "").replace(/^www\./, "").split(".");
  if (parts.length <= 2) return parts.join(".");
  const two = ["co.uk", "com.au", "co.jp", "com.br", "co.nz", "org.uk", "gov.uk", "com.mx", "co.in"];
  const last2 = parts.slice(-2).join(".");
  return two.includes(last2) ? parts.slice(-3).join(".") : last2;
}
function hostOf(url) { try { return new URL(url).hostname.replace(/^www\./, ""); } catch { return ""; } }

// ---------- filling ----------

async function fillInto(tabId, frameId, url, id, only, master) {
  const r = await vault("fill", { id, url, ...(master ? { master } : {}) });
  if (!r.ok) return r;
  const payload = { type: "vault-fill", username: r.username, password: r.password, code: r.code, only };
  await chrome.tabs.sendMessage(tabId, payload, { frameId }).catch(() => {});
  if (!only && r.password) await setTabMemo(tabId, { lastPick: { id, base: baseDomain(hostOf(url)), at: Date.now() } });
  if (only === "username") await setTabMemo(tabId, { lastPick: { id, base: baseDomain(hostOf(url)), at: Date.now() } });
  if (r.code) await setTabMemo(tabId, { code: { id, base: baseDomain(hostOf(url)), at: Date.now() } });
  return { ok: true, filled: true };
}

async function generateInto(tabId, frameId, url) {
  const opts = (await chrome.storage.local.get("gen")).gen || {};
  const r = await vault("generate", opts);
  if (!r.ok) return r;
  await chrome.tabs.sendMessage(tabId, { type: "vault-generated", password: r.password }, { frameId }).catch(() => {});
  return { ok: true };
}

// ---------- messages ----------

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  handle(msg, sender).then(reply, (e) => reply({ ok: false, error: String(e) }));
  return true;
});

async function handle(msg, sender) {
  const fromExtensionPage = sender.id === chrome.runtime.id && sender.url?.startsWith(chrome.runtime.getURL(""));
  const tabId = sender.tab?.id;

  switch (msg.type) {
    // ----- content scripts (page frames). The address is Chrome's, not the page's. -----
    case "page-logins": {
      if (!sender.tab || fromExtensionPage) return { ok: false };
      const r = await vault("logins", { url: sender.url }, 8000);
      if (!r.ok) return { ok: false, code: r.code };
      const memo = await tabMemo(tabId);
      const base = baseDomain(hostOf(sender.url));
      const lp = memo.lastPick && memo.lastPick.base === base && Date.now() - memo.lastPick.at < LAST_PICK_MS ? memo.lastPick.id : null;
      const cd = memo.code && memo.code.base === base && Date.now() - memo.code.at < LAST_PICK_MS ? memo.code.id : null;
      return { ok: true, count: r.logins.length, lastPick: lp, codeFor: cd };
    }
    case "open-menu": {
      if (!sender.tab || fromExtensionPage) return { ok: false };
      const token = b64url(crypto.getRandomValues(new Uint8Array(18)));
      await menus.set(token, { tabId, frameId: sender.frameId, url: sender.url, mode: msg.mode, at: Date.now() });
      return { ok: true, token };
    }
    case "captured": {
      if (!sender.tab || fromExtensionPage) return { ok: false };
      const host = hostOf(sender.url);
      const { never = [] } = await chrome.storage.local.get("never");
      if (!host || never.includes(baseDomain(host))) return { ok: true };
      let username = msg.username || "";
      if (!username) {
        const t = (await tabMemo(tabId)).typedUser;
        if (t && t.base === baseDomain(host) && Date.now() - t.at < LAST_PICK_MS) username = t.value;
      }
      msg.username = username;
      const r = await vault("check", { url: sender.url, username, password: msg.password || "" }, 8000);
      if (!r.ok || (r.status !== "new" && r.status !== "update")) return { ok: true };
      await setTabMemo(tabId, { offer: { status: r.status, id: r.id || "", title: r.title, host, url: sender.url,
        username: msg.username || "", password: msg.password, at: Date.now() } });
      await chrome.tabs.sendMessage(tabId, { type: "vault-offer" }, { frameId: 0 }).catch(() => {});
      return { ok: true };
    }
    case "focus-frame": {
      if (!sender.tab || fromExtensionPage) return { ok: false };
      await setTabMemo(tabId, { focusFrame: { frameId: sender.frameId, url: sender.url, at: Date.now() } });
      return { ok: true };
    }
    case "typed-user": {
      if (!sender.tab || fromExtensionPage || !msg.username) return { ok: false };
      await setTabMemo(tabId, { typedUser: { value: String(msg.username).slice(0, 200), base: baseDomain(hostOf(sender.url)), at: Date.now() } });
      return { ok: true };
    }
    case "offer-pending": {
      if (!sender.tab || sender.frameId !== 0) return { ok: false };
      const memo = await tabMemo(tabId);
      return { ok: !!(memo.offer && Date.now() - memo.offer.at < SAVE_OFFER_MS) };
    }

    // ----- extension pages only (popup, in-page menu, save bar) -----
    default:
      if (!fromExtensionPage) return { ok: false, error: "Not allowed." };
      return handleUI(msg, sender);
  }
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function handleUI(msg, sender) {
  switch (msg.type) {
    case "status": { const r = await vault("status", {}, 8000); return { ...r, mode: await mode() }; }
    case "link-start": return Local.linkStart();
    case "link-poll": return Local.linkPoll();
    case "unlink": return Local.unlink();
    case "use-mac": await chrome.storage.local.set({ mode: "mac" }); return { ok: true };
    case "pair-code": { const id = await identity(); return { ok: true, code: await pairCode(id.client, id.key) }; }
    case "pair": return vault("pair", { name: msg.name || "Chrome" });
    case "unlock": return vault("unlock", { master: msg.master || "" }, 60000);
    case "lock": return vault("lock");
    case "search": return vault("search", { q: msg.q || "" }, 8000);
    case "code": return vault("code", { id: msg.id }, 8000);
    case "generate": {
      if (msg.options) await chrome.storage.local.set({ gen: msg.options });
      return vault("generate", { ...(msg.options || {}), remember: msg.remember ? "1" : "0" }, 8000);
    }

    // Popup: logins for the page in the active tab, and actions on it.
    case "tab-logins": {
      const tab = await activeTab();
      if (!tab?.url || !/^https?:/.test(tab.url)) return { ok: true, host: "", logins: [], usernames: [] };
      return vault("logins", { url: tab.url }, 8000);
    }
    case "tab-fill": {
      const tab = await activeTab();
      if (!tab?.url || !/^https?:/.test(tab.url)) return { ok: false, error: "Open a website first." };
      const frame = (await tabMemo(tab.id)).focusFrame;
      const target = frame && frame.at > Date.now() - 5 * 60 * 1000 ? frame : { frameId: 0, url: tab.url };
      return fillInto(tab.id, target.frameId, target.url, msg.id, undefined, msg.master);
    }
    case "copy-secret": {
      const tab = await activeTab();
      const r = await vault("fill", { id: msg.id, url: tab?.url || "", purpose: "copy", ...(msg.master ? { master: msg.master } : {}) });
      if (!r.ok) return r;
      return { ok: true, value: msg.field === "username" ? r.username : msg.field === "code" ? r.code : r.password };
    }

    case "tab-generated": {
      const tab = await activeTab();
      if (!tab?.url || !/^https?:/.test(tab.url)) return { ok: false, error: "Open a website first." };
      const frame = (await tabMemo(tab.id)).focusFrame;
      const target = frame && frame.at > Date.now() - 5 * 60 * 1000 ? frame : { frameId: 0 };
      await chrome.tabs.sendMessage(tab.id, { type: "vault-generated", password: msg.password }, { frameId: target.frameId }).catch(() => {});
      return { ok: true };
    }

    // In-page menu (extension iframe). It knows only its token.
    case "menu-data": {
      const m = await menus.get(msg.token);
      if (!m) return { ok: false, code: "expired" };
      const [r, memo] = await Promise.all([vault("logins", { url: m.url }, 8000), tabMemo(m.tabId)]);
      if (!r.ok) return r;
      await setTabMemo(m.tabId, { focusFrame: { frameId: m.frameId, url: m.url, at: Date.now() } });
      const base = baseDomain(hostOf(m.url));
      const lp = memo.lastPick && memo.lastPick.base === base && Date.now() - memo.lastPick.at < LAST_PICK_MS ? memo.lastPick.id : null;
      let code = null;
      if (m.mode === "otp" && memo.code && memo.code.base === base && Date.now() - memo.code.at < LAST_PICK_MS) {
        const c = await vault("code", { id: memo.code.id }, 8000);
        const item = r.logins.find((l) => l.id === memo.code.id);
        if (c.ok) code = { id: memo.code.id, code: c.code, seconds: c.seconds, title: item?.title || "", username: item?.username || "" };
      }
      return { ok: true, mode: m.mode, host: r.host, logins: r.logins, lastPick: lp, code };
    }
    case "menu-fill": {
      const m = await menus.get(msg.token);
      if (!m) return { ok: false, code: "expired" };
      return fillInto(m.tabId, m.frameId, m.url, msg.id, msg.only);
    }
    case "menu-code": {
      const m = await menus.get(msg.token);
      if (!m) return { ok: false, code: "expired" };
      const c = await vault("code", { id: msg.id }, 8000);
      if (c.ok) await chrome.tabs.sendMessage(m.tabId, { type: "vault-fill", code: c.code, only: "code" }, { frameId: m.frameId }).catch(() => {});
      return c;
    }
    case "menu-generate": {
      const m = await menus.get(msg.token);
      if (!m) return { ok: false, code: "expired" };
      return generateInto(m.tabId, m.frameId, m.url);
    }
    case "menu-close": {
      const m = await menus.get(msg.token);
      if (m) await chrome.tabs.sendMessage(m.tabId, { type: "vault-menu-close" }, { frameId: m.frameId }).catch(() => {});
      return { ok: true };
    }

    // Save bar (extension iframe in the top frame of the tab).
    case "offer-data": {
      const memo = await tabMemo(sender.tab.id);
      const o = memo.offer;
      if (!o || Date.now() - o.at > SAVE_OFFER_MS) return { ok: false };
      const { usernames = [] } = await vault("logins", { url: o.url }, 8000);
      return { ok: true, status: o.status, title: o.title, host: o.host, username: o.username, usernames };
    }
    case "offer-answer": {
      const tabId = sender.tab.id;
      const memo = await tabMemo(tabId);
      const o = memo.offer;
      await setTabMemo(tabId, { offer: null });
      chrome.tabs.sendMessage(tabId, { type: "vault-offer-close" }, { frameId: 0 }).catch(() => {});
      if (!o) return { ok: false };
      if (msg.answer === "never") {
        const { never = [] } = await chrome.storage.local.get("never");
        never.push(baseDomain(o.host));
        await chrome.storage.local.set({ never: [...new Set(never)] });
        return { ok: true };
      }
      if (msg.answer !== "save") return { ok: true };
      return vault("save", { url: o.url, id: o.status === "update" ? o.id : "", username: msg.username ?? o.username,
        password: o.password, title: msg.title || o.title });
    }
  }
  return { ok: false, error: "Unknown request." };
}

// ---------- helpers ----------

function hex(b) { return [...b].map((x) => x.toString(16).padStart(2, "0")).join(""); }
function b64url(b) { return btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }

// Same six digits the Mac app shows: SHA-256("vault-pair|client|key"), first 4 bytes mod 1,000,000.
async function pairCode(client, key) {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`vault-pair|${client}|${key}`)));
  const n = ((d[0] << 24) >>> 0) + (d[1] << 16) + (d[2] << 8) + d[3];
  const s = String(n % 1000000).padStart(6, "0");
  return s.slice(0, 3) + " " + s.slice(3);
}
