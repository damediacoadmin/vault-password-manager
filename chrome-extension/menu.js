// The list that drops down under a login box. It runs as an extension page, so the web page
// it sits on cannot read the names or usernames in it. It only knows its one-time token.
const token = location.hash.slice(1);
const list = $("#list");
let rows = [], sel = 0;

function resize() { parent.postMessage({ vaultHeight: $("#box").getBoundingClientRect().height + 2 }, "*"); }
function close() { send({ type: "menu-close", token }); parent.postMessage({ vaultClose: true }, "*"); }
$("#close").onclick = close;

function row(icon, title, sub, action, extra) {
  const r = h("div", { class: "row click", role: "option", tabindex: "-1", onclick: action }, icon, h("div", { class: "who" }, h("div", { class: "t" }, title), sub ? h("div", { class: "u" }, sub) : null), extra);
  rows.push({ el: r, action });
  return r;
}

async function run(fn, el) {
  el?.classList.add("sel");
  const r = await fn();
  if (r && !r.ok) {
    list.replaceChildren(h("div", { class: "note" }, r.code === "denied" ? "Touch ID was not confirmed." : r.error || "That did not work."));
    resize();
  }
}

async function load() {
  const d = await send({ type: "menu-data", token });
  if (!d.ok) {
    const msg = d.code === "locked" ? "Vault is locked on your Mac. Click the Vault button in Chrome's toolbar to unlock."
      : d.code === "unpaired" ? "Click the Vault button in Chrome's toolbar to connect this browser."
      : d.code === "offline" || d.code === "nohelper" ? "Open Vault on your Mac." : d.error || "Vault is not available.";
    list.replaceChildren(h("div", { class: "note" }, msg));
    return resize();
  }
  $("#where").textContent = d.host ? `Vault · ${d.host}` : "Vault";
  rows = []; const kids = [];

  if (d.mode === "otp" && d.code) {
    kids.push(row(ring(d.code.seconds), h("span", { class: "code" }, prettyCode(d.code.code)), `2FA code · ${d.code.title}`,
      () => run(() => send({ type: "menu-code", token, id: d.code.id }))));
  }
  if (d.mode === "new") {
    kids.push(row(h("div", { class: "tile gen", "aria-hidden": "true" }, "✱"), "Use a strong password", "Fills the password boxes for you",
      () => run(() => send({ type: "menu-generate", token }))));
  }
  const logins = [...d.logins];
  const pick = d.mode === "login" ? d.lastPick : null;
  if (pick) logins.sort((a, b) => (b.id === pick) - (a.id === pick));
  for (const l of logins) {
    const extra = l.id === pick ? h("span", { class: "tag" }, "Continue") : null;
    kids.push(row(tile(l), l.title, l.username || "No username", (e) => run(() => send({ type: "menu-fill", token, id: l.id }), e.currentTarget), extra));
  }
  if (!kids.length) kids.push(h("div", { class: "note" }, d.host ? `No logins saved for ${d.host}.` : "No logins for this page."));
  list.replaceChildren(...kids);
  highlight(0);
  resize();
}

function highlight(i) {
  if (!rows.length) return;
  sel = (i + rows.length) % rows.length;
  rows.forEach((r, j) => r.el.classList.toggle("sel", j === sel));
  rows[sel].el.scrollIntoView({ block: "nearest" });
}

addEventListener("keydown", (e) => {
  if (e.key === "Escape") close();
  if (e.key === "ArrowDown") { e.preventDefault(); highlight(sel + 1); }
  if (e.key === "ArrowUp") { e.preventDefault(); highlight(sel - 1); }
  if (e.key === "Enter" && rows[sel]) rows[sel].action({ currentTarget: rows[sel].el });
});
new ResizeObserver(resize).observe($("#box"));
load();
