// The Vault toolbar popup: logins for this site, search, and the password generator.
const app = $("#app");
let tab = "site";
let timers = [];

function setState(text, on) { $("#state").textContent = text; $("#dot").classList.toggle("on", !!on); }
function clearTimers() { timers.forEach(clearInterval); timers = []; }

let currentMode = "mac";

async function start() {
  const s = await send({ type: "status" });
  currentMode = s.mode || "mac";
  if (s.ok && s.state === "unlocked") return main();
  if (currentMode === "phone") return s.code === "unpaired" ? connect() : lockedPhone(s.error);
  if (s.ok && s.state === "locked") return locked();
  switch (s.code) {
    case "locked": return locked();
    case "disabled": return message("Chrome is turned off", "Turn on “Allow the Chrome extension” in Vault on your Mac, under Chrome, or link with your iPhone instead.");
    case "empty": return message("Set up Vault first", "Open Vault on your Mac and create or join your vault.");
    default: return connect();
  }
}

function message(title, body) {
  setState("Offline");
  app.replaceChildren(h("main", {}, h("div", { class: "hero" }, h("h1", {}, title), h("p", {}, body),
    h("button", { class: "btn primary", onclick: () => qrScreen("link") }, "Link with iPhone"),
    h("button", { class: "btn", style: "margin-top:8px", onclick: start }, "Try again"))));
}

// First run: link to the iPhone (recommended) or use the Vault app on this Mac.
function connect(note) {
  setState("Not connected");
  app.replaceChildren(h("main", {}, h("div", { class: "hero" },
    h("h1", {}, "Connect Chrome"),
    h("p", {}, "Scan a QR code with Vault on your iPhone. Chrome gets its own end-to-end encrypted copy of your logins that stays in sync."),
    h("button", { class: "btn primary", onclick: () => qrScreen("link") }, "Link with iPhone"),
    h("button", { class: "btn", style: "margin-top:8px", onclick: macPair }, "Use Vault on this Mac instead"),
    note ? h("p", { class: "muted", style: "margin:12px 0 0;font-size:12px" }, note) : null)));
}

// Shows the QR code and waits for the iPhone to answer through the sync server.
async function qrScreen(purpose) {
  setState(purpose === "unlock" ? "Locked" : "Linking");
  clearTimers();
  const box = h("div", { class: "qr", role: "img", "aria-label": "QR code to scan with Vault on your iPhone" });
  const note = h("p", { class: "mid", style: "margin:12px 0 0;font-size:13px", "aria-live": "polite" }, "Waiting for your iPhone…");
  const back = h("button", { class: "btn", style: "margin-top:12px", onclick: () => { clearTimers(); start(); } }, "Back");
  app.replaceChildren(h("main", {}, h("div", { class: "hero" },
    h("h1", {}, purpose === "unlock" ? "Unlock with iPhone" : "Scan with your iPhone"),
    h("p", {}, "On your iPhone open Vault, go to Settings, tap Link Chrome, and scan this code."),
    box, note, back)));
  const r = await send({ type: "link-start" });
  if (!r.ok) { note.textContent = r.error || "Could not make a code."; note.className = "red"; return; }
  drawQR(box, r.text);
  let busy = false;
  timers.push(setInterval(async () => {
    if (busy) return; busy = true;
    const p = await send({ type: "link-poll" });
    busy = false;
    if (p.ok) { clearTimers(); currentMode = "phone"; tab = "site"; return main(); }
    if (p.code === "expired") { clearTimers(); return qrScreen(purpose); }
    if (p.code === "error") { clearTimers(); note.textContent = p.error; note.className = "red"; back.textContent = "Try again"; back.onclick = () => qrScreen(purpose); }
  }, 1500));
}

function drawQR(el, text) {
  const q = qrcode(0, "M");
  q.addData(text); q.make();
  const n = q.getModuleCount(), quiet = 3, size = n + quiet * 2;
  let path = "";
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) if (q.isDark(y, x)) path += `M${x + quiet} ${y + quiet}h1v1h-1z`;
  el.innerHTML = `<svg viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges" width="100%" height="100%"><rect width="${size}" height="${size}" fill="#fff"/><path d="${path}" fill="#0B0C0E"/></svg>`;
  el.dataset.link = text;
}

async function macPair() {
  await send({ type: "use-mac" });
  setState("Not connected");
  const { code } = await send({ type: "pair-code" });
  const btn = h("button", { class: "btn primary" }, "Connect to Vault on this Mac");
  const note = h("p", { class: "mid", style: "margin:12px 0 0;font-size:13px" }, "Vault on your Mac will show the same code. Check it matches, click Connect, then use Touch ID.");
  btn.onclick = async () => {
    btn.disabled = true; btn.textContent = "Waiting for your Mac…";
    const r = await send({ type: "pair", name: browserName() });
    if (r.ok) return start();
    btn.disabled = false; btn.textContent = "Try again";
    note.textContent = r.error || "Not connected."; note.className = "red";
  };
  app.replaceChildren(h("main", {}, h("div", { class: "hero" },
    h("h1", {}, "Use Vault on this Mac"), h("p", {}, "Chrome asks the Vault app on this Mac for each login. Your passwords stay in the app."),
    h("div", { class: "eyebrow", style: "margin-bottom:8px" }, "Your code"), h("div", { class: "pair", "aria-label": "Pairing code " + code }, code),
    btn, note, h("button", { class: "btn", style: "margin-top:8px", onclick: () => qrScreen("link") }, "Link with iPhone instead"))));
}

function browserName() {
  const brand = navigator.userAgentData?.brands?.find((b) => /Chrome/.test(b.brand))?.brand || "Chrome";
  return `${brand} on this Mac`;
}

function locked() {
  if (currentMode === "phone") return lockedPhone();
  setState("Locked");
  const btn = h("button", { class: "btn outline", style: "height:52px;justify-content:space-between;padding:0 16px" }, "Unlock with Touch ID", h("span", { "aria-hidden": "true" }, "→"));
  const note = h("p", { class: "mid", style: "margin:10px 0 0;font-size:13px" }, "Vault asks for Touch ID on your Mac.");
  btn.onclick = async () => {
    btn.disabled = true; note.textContent = "Look for Touch ID on your Mac…";
    const r = await send({ type: "unlock" });
    if (r.ok && r.state === "unlocked") return main();
    btn.disabled = false; note.textContent = r.error || "Still locked."; note.className = "red";
  };
  app.replaceChildren(h("main", {}, h("div", { class: "hero" }, h("h1", {}, "Locked."), h("p", {}, "Your logins are sealed in Vault on this Mac."), btn, note)));
}

// Linked to the iPhone: unlock by scanning again, or with the master password.
function lockedPhone(err) {
  setState("Locked");
  const pw = h("input", { class: "field", type: "password", placeholder: "Master password", "aria-label": "Master password", autocomplete: "current-password" });
  const go = h("button", { class: "btn", style: "margin-top:8px" }, "Unlock");
  const note = h("p", { class: err ? "red" : "mid", style: "margin:10px 0 0;font-size:13px" }, err || "Chrome locks after 30 idle minutes, when your Mac locks, and when Chrome quits.");
  const submit = async () => {
    if (!pw.value) return;
    go.disabled = true; go.textContent = "Unlocking…";
    const r = await send({ type: "unlock", master: pw.value });
    pw.value = "";
    if (r.ok) return main();
    go.disabled = false; go.textContent = "Unlock"; note.textContent = r.error || "Still locked."; note.className = "red";
  };
  go.onclick = submit;
  pw.addEventListener("keydown", (e) => { if (e.key === "Enter") submit(); });
  const unlinkBtn = h("button", { class: "caps plain", onclick: async () => {
    if (unlinkBtn.dataset.sure) { await send({ type: "unlink" }); currentMode = "mac"; return connect(); }
    unlinkBtn.dataset.sure = "1"; unlinkBtn.textContent = "Tap again to unlink";
  } }, "Unlink this browser");
  app.replaceChildren(h("main", {}, h("div", { class: "hero" },
    h("h1", {}, "Locked."), h("p", {}, "Your logins are sealed in Chrome."),
    h("button", { class: "btn primary", style: "height:48px", onclick: () => qrScreen("unlock") }, "Unlock with iPhone"),
    h("div", { class: "eyebrow", style: "margin:18px 0 8px" }, "Or use your master password"), pw, go, note,
    h("div", { style: "margin-top:14px" }, unlinkBtn))));
  if (!err) pw.focus();
}

// A login saved for a different site than this one needs the master password (iPhone-linked mode).
function confirmMaster(l, retry) {
  const pw = h("input", { class: "field", type: "password", placeholder: "Master password", "aria-label": "Master password" });
  const note = h("p", { class: "mid", style: "margin:10px 0 0;font-size:13px" }, `${l.title} is saved for ${l.host || "another site"}, not this page. Enter your master password to use it here.`);
  const go = async () => { const m = pw.value; pw.value = ""; if (m) await retry(m); };
  pw.addEventListener("keydown", (e) => { if (e.key === "Enter") go(); });
  clearTimers();
  app.replaceChildren(h("main", {}, h("div", { class: "hero" }, h("h1", {}, "Different site"), note, h("div", { style: "height:12px" }), pw,
    h("div", { class: "two", style: "margin-top:8px" }, h("button", { class: "btn", onclick: main }, "Cancel"), h("button", { class: "btn primary", onclick: go }, "Continue")))));
  pw.focus();
}

// ---------- unlocked ----------

function main() {
  setState("Unlocked", true);
  const tabs = [["site", "This site"], ["search", "Search"], ["gen", "Generate"]];
  const nav = h("nav", { role: "tablist" }, tabs.map(([k, label]) =>
    h("button", { role: "tab", "aria-selected": String(tab === k), onclick: () => { tab = k; main(); } }, label)));
  const body = h("main", {});
  const footer = h("footer", {}, h("span", { class: "eyebrow" }, currentMode === "phone" ? "Synced with iPhone" : "⌘⇧L opens Vault"),
    h("button", { class: "caps", onclick: async () => { await send({ type: "lock" }); locked(); } }, "Lock"));
  app.replaceChildren(nav, body, footer);
  clearTimers();
  if (tab === "site") site(body);
  if (tab === "search") search(body);
  if (tab === "gen") generator(body);
}

async function site(body) {
  const r = await send({ type: "tab-logins" });
  if (!r.ok) return start();
  const head = h("div", { class: "sub eyebrow" }, r.host ? `Saved for ${r.host}` : "Not a website");
  if (!r.logins.length) {
    body.replaceChildren(head, h("div", { class: "empty" }, r.host ? `No logins saved for ${r.host} yet. Sign in or sign up and Vault offers to save it.` : "Open a website to see its logins."),
      h("div", { class: "pad two" }, h("button", { class: "btn", onclick: () => { tab = "search"; main(); } }, "Search all"),
        h("button", { class: "btn", onclick: () => { tab = "gen"; main(); } }, "New password")));
    return;
  }
  body.replaceChildren(head, h("div", { class: "list" }, r.logins.map((l) => loginRow(l, true))));
}

const ICONS = {
  user: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="5.5" r="2.7"/><path d="M2.8 14c.6-2.8 2.7-4.3 5.2-4.3s4.6 1.5 5.2 4.3"/></svg>',
  key: '<svg viewBox="0 0 16 16" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="5" cy="8" r="2.8"/><path d="M7.8 8h6.2M12 8v2.4M14 8v1.6"/></svg>',
};
function iconButton(kind, label, onclick) {
  const b = h("button", { class: "ib", title: label, "aria-label": label, onclick });
  b.innerHTML = ICONS[kind];
  return b;
}

function loginRow(l, sameSite) {
  const who = h("div", { class: "who" }, h("div", { class: "t" }, l.title), h("div", { class: "u" }, l.username || l.host || "No username"));
  if (l.totp) who.append(otpChip(l));
  const acts = h("div", { class: "acts" },
    iconButton("user", "Copy username", (e) => { e.stopPropagation(); copyField(l, "username"); }),
    iconButton("key", sameSite || currentMode === "phone" ? "Copy password" : "Copy password (asks for Touch ID)", (e) => { e.stopPropagation(); copyField(l, "password"); }),
    h("button", { class: "caps outline", onclick: (e) => { e.stopPropagation(); fill(l); } }, "Fill"));
  return h("div", { class: "row" }, tile(l), who, acts);
}

function otpChip(l) {
  const chip = h("button", { class: "otp", title: "Copy 2FA code", "aria-label": "Copy 2FA code" });
  let code = "", left = 0;
  const draw = () => chip.replaceChildren(ring(left), h("span", { class: "code", style: "font-size:13px" }, prettyCode(code)), h("span", { class: "mono muted", style: "font-size:11px" }, `${left}s`));
  const load = async () => { const c = await send({ type: "code", id: l.id }); if (c.ok) { code = c.code; left = c.seconds; draw(); } };
  chip.onclick = async (e) => { e.stopPropagation(); if (code) await copySecret(code, "2FA code"); };
  load();
  timers.push(setInterval(() => { left -= 1; if (left <= 0) load(); else draw(); }, 1000));
  return chip;
}

async function fill(l, master) {
  const r = await send({ type: "tab-fill", id: l.id, master });
  if (r.ok) return window.close();
  if (r.code === "confirm") return confirmMaster(l, (m) => fill(l, m));
  if (master) main();
  toast(r.code === "denied" ? "Touch ID not confirmed" : r.error || "Could not fill");
}

async function copyField(l, field, master) {
  const r = await send({ type: "copy-secret", id: l.id, field, master });
  if (r.code === "confirm") return confirmMaster(l, (m) => copyField(l, field, m));
  if (master) main();
  if (!r.ok) return toast(r.code === "denied" ? "Touch ID not confirmed" : r.error || "Could not copy");
  await copySecret(r.value || "", field === "username" ? "Username" : "Password");
}

function search(body) {
  const input = h("input", { class: "field", type: "text", placeholder: "Search names, usernames, sites", "aria-label": "Search logins", autofocus: true, spellcheck: "false" });
  const results = h("div", { class: "list" });
  const note = h("div", { class: "sub eyebrow" }, "Favorites");
  let seq = 0;
  const run = async () => {
    const mine = ++seq;
    const r = await send({ type: "search", q: input.value });
    if (mine !== seq) return;
    note.textContent = input.value ? `${r.logins?.length || 0} found` : "Favorites";
    clearTimers();
    results.replaceChildren(...(r.logins || []).map((l) => loginRow(l, false)));
    if (!r.logins?.length) results.append(h("div", { class: "empty" }, input.value ? "Nothing matches." : "Star logins in Vault to see them here."));
  };
  input.addEventListener("input", run);
  body.replaceChildren(h("div", { class: "pad" }, input), h("div", { style: "height:8px" }), note, results);
  input.focus();
  run();
}

// ---------- generator ----------

const DEFAULTS = { style: "Characters", length: 20, words: 5, symbols: "1", digits: "1" };

async function generator(body) {
  let o = { ...DEFAULTS, ...((await chrome.storage.local.get("gen")).gen || {}) };
  const out = h("div", { class: "gen", "aria-live": "polite" });
  const bits = h("span", { class: "eyebrow" });
  const strength = h("span", { class: "eyebrow amber" });
  let current = "";

  const make = async () => {
    const r = await send({ type: "generate", options: o, remember: true });
    if (!r.ok) { out.textContent = r.error || "Could not make a password."; return; }
    current = r.password; out.textContent = current;
    const b = entropy(current, o);
    bits.textContent = `${Math.round(b)} bits`;
    strength.textContent = b >= 100 ? "Very strong" : b >= 70 ? "Strong" : b >= 50 ? "Fair" : "Weak";
  };

  const seg = h("div", { class: "seg", role: "group", "aria-label": "Style" }, ["Characters", "Words"].map((s) =>
    h("button", { "aria-pressed": String(o.style === s), onclick: () => { o.style = s; generator(body); } }, s)));
  const isWords = o.style === "Words";
  const lenLabel = h("span", { class: "mono" }, isWords ? `${o.words} words` : `${o.length} characters`);
  const slider = h("input", { type: "range", min: isWords ? 3 : 8, max: isWords ? 10 : 64, value: isWords ? o.words : o.length, "aria-label": "Length" });
  slider.oninput = () => { if (isWords) o.words = +slider.value; else o.length = +slider.value; lenLabel.textContent = isWords ? `${o.words} words` : `${o.length} characters`; make(); };
  const toggle = (key, label) => {
    const box = h("input", { type: "checkbox", class: "switch", "aria-label": label });
    box.checked = o[key] === "1";
    box.onchange = () => { o[key] = box.checked ? "1" : "0"; make(); };
    return h("label", { class: "opt" }, h("span", {}, label), box);
  };

  body.replaceChildren(h("div", { class: "pad" },
    out, h("div", { class: "strength" }, strength, bits),
    h("div", { class: "opts" },
      h("div", { class: "opt" }, h("span", {}, "Style"), seg),
      h("div", { class: "opt" }, lenLabel, slider),
      toggle("symbols", "Special characters"),
      toggle("digits", "Numbers")),
    h("div", { class: "two" },
      h("button", { class: "btn", onclick: make }, "New one"),
      h("button", { class: "btn", onclick: () => current && copySecret(current, "Password") }, "Copy")),
    h("button", { class: "btn primary", style: "margin-top:8px", onclick: async () => { if (!current) return; await send({ type: "tab-generated", password: current }); window.close(); } }, "Fill on this page")));
  make();
}

function entropy(p, o) {
  if (o.style === "Words") return o.words * Math.log2(6216) + (o.digits === "1" ? Math.log2(10) : 0) + (o.symbols === "1" ? Math.log2(30) : 0);
  let pool = 0;
  if (/[a-z]/.test(p)) pool += 26; if (/[A-Z]/.test(p)) pool += 26; if (/[0-9]/.test(p)) pool += 10; if (/[^a-zA-Z0-9]/.test(p)) pool += 30;
  return p.length * Math.log2(pool || 1);
}

start();
