// Small helpers shared by the extension pages.
const send = (msg) => chrome.runtime.sendMessage(msg).catch(() => ({ ok: false, error: "Vault extension restarted. Try again." }));
const $ = (s, el = document) => el.querySelector(s);
function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) el.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null) el.append(k.nodeType ? k : document.createTextNode(String(k)));
  return el;
}
function tile(l) { return h("div", { class: "tile" + (l.favorite ? " fav" : ""), "aria-hidden": "true" }, (l.title || "?").trim().charAt(0).toUpperCase()); }
function prettyCode(c) { return c && c.length === 6 ? c.slice(0, 3) + " " + c.slice(3) : c || ""; }
function ring(seconds, period = 30) {
  const ns = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(ns, "svg"); svg.setAttribute("viewBox", "0 0 16 16"); svg.setAttribute("class", "ring");
  const c = document.createElementNS(ns, "circle");
  c.setAttribute("cx", 8); c.setAttribute("cy", 8); c.setAttribute("r", 6); c.setAttribute("fill", "none");
  c.setAttribute("stroke", "#F2A541"); c.setAttribute("stroke-width", 2);
  const len = 2 * Math.PI * 6; c.setAttribute("stroke-dasharray", `${len * seconds / period} ${len}`);
  c.setAttribute("transform", "rotate(-90 8 8)");
  const bg = document.createElementNS(ns, "circle");
  bg.setAttribute("cx", 8); bg.setAttribute("cy", 8); bg.setAttribute("r", 6); bg.setAttribute("fill", "none"); bg.setAttribute("stroke", "#2A2D33"); bg.setAttribute("stroke-width", 2);
  svg.append(bg, c); return svg;
}
let toastTimer;
function toast(text) {
  let t = $(".toast"); if (!t) { t = h("div", { class: "toast", role: "status" }); document.body.append(t); }
  t.textContent = text; t.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove("show"), 1600);
}
// Copied secrets are wiped from the clipboard after 60 seconds if nothing else replaced them.
async function copySecret(value, label) {
  await navigator.clipboard.writeText(value);
  toast(`${label} copied`);
  setTimeout(async () => { try { if ((await navigator.clipboard.readText()) === value) await navigator.clipboard.writeText(""); } catch {} }, 60000);
}
