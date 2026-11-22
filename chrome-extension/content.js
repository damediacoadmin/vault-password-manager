// Vault for Chrome: runs in each web page frame (in Chrome's isolated world, so the page's own
// scripts cannot read this code's variables). It finds login boxes, shows the Vault button and
// menu, fills what you pick, and notices new sign-ins so Vault can offer to save them.
// The list of logins is shown inside an extension frame, so the page never sees it.
(() => {
  if (window.__vaultLoaded) return;
  window.__vaultLoaded = true;

  const EXT = chrome.runtime.getURL("");
  const isTop = window === window.top;
  let active = null;          // the field the menu belongs to
  let menu = null;            // { host, frame, token }
  let button = null;          // shadow host for the in-field button
  let dismissed = new WeakSet();
  let cache = null;           // { at, data }
  let lastGenerated = "";

  // ---------- field detection ----------

  const USER_RE = /user|e-?mail|login|account|identifier|phone|mobile|handle|member/i;
  const OTP_RE = /one.?time|otp|2fa|two.?factor|totp|mfa|verification.?code|verify.?code|security.?code|auth.?code|passcode|^code$|token/i;
  const NEW_RE = /new|confirm|repeat|retype|again|signup|sign.?up|register|create|choose/i;
  const OLD_RE = /current|old|existing/i;

  function hints(el) {
    return [el.name, el.id, el.getAttribute("placeholder"), el.getAttribute("aria-label"), el.autocomplete,
      el.labels?.[0]?.textContent, el.getAttribute("data-testid")].filter(Boolean).join(" ");
  }

  function visible(el) {
    if (!el.isConnected || el.disabled || el.readOnly) return false;
    const r = el.getBoundingClientRect();
    if (r.width < 30 || r.height < 12) return false;
    const st = getComputedStyle(el);
    return st.visibility !== "hidden" && st.display !== "none" && Number(st.opacity) > 0.05;
  }

  const isPassword = (el) => el instanceof HTMLInputElement && (el.type === "password" || el.dataset.vaultWasPassword === "1");
  const isTextual = (el) => el instanceof HTMLInputElement && ["text", "email", "tel", "number", ""].includes(el.type);

  function isOTP(el) {
    if (!isTextual(el)) return false;
    if (el.autocomplete === "one-time-code") return true;
    const max = el.maxLength > 0 ? el.maxLength : 99;
    return OTP_RE.test(hints(el)) && max <= 10;
  }

  function scopeOf(el) { return el.form || el.closest("form,[role=form],[role=dialog]") || document; }

  function passwordsIn(scope) { return [...scope.querySelectorAll("input")].filter((i) => isPassword(i) && visible(i)); }

  function isNewPassword(el) {
    if (!isPassword(el)) return false;
    const ac = (el.autocomplete || "").toLowerCase();
    if (ac.includes("new-password")) return true;
    if (ac.includes("current-password")) return false;
    const h = hints(el);
    if (OLD_RE.test(h)) return false;
    if (NEW_RE.test(h)) return true;
    const scope = scopeOf(el);
    if (passwordsIn(scope).length >= 2) return true;
    const formText = (scope.textContent || "").slice(0, 3000);
    return /create (an |your )?account|sign up|register|get started|join now/i.test(formText) && !/forgot/i.test(formText);
  }

  function isUsername(el) {
    if (!isTextual(el) || isOTP(el)) return false;
    const ac = (el.autocomplete || "").toLowerCase();
    if (ac.includes("username") || ac === "email" || el.type === "email") return true;
    if (/search|query|coupon|promo|zip|postal|city|address|first|last|name.?on|card/i.test(hints(el)) && !USER_RE.test(hints(el))) return false;
    if (USER_RE.test(hints(el))) return true;
    // The text box right before a password box is the username.
    const scope = scopeOf(el);
    const inputs = [...scope.querySelectorAll("input")].filter(visible);
    const i = inputs.indexOf(el);
    return i >= 0 && inputs.slice(i + 1, i + 3).some(isPassword);
  }

  function modeOf(el) {
    if (!(el instanceof HTMLInputElement)) return null;
    if (isPassword(el)) return isNewPassword(el) ? "new" : "login";
    if (isOTP(el)) return "otp";
    if (isUsername(el)) return "login";
    return null;
  }

  function usernameFor(scope, near) {
    const inputs = [...scope.querySelectorAll("input")].filter((i) => visible(i) && isUsername(i));
    if (!near) return inputs[0] || null;
    const before = inputs.filter((i) => near.compareDocumentPosition(i) & Node.DOCUMENT_POSITION_PRECEDING);
    return before[before.length - 1] || inputs[0] || null;
  }

  // ---------- setting values the way a person typing would ----------

  function setValue(el, value) {
    if (!el || value == null) return;
    el.focus({ preventScroll: true });
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    setter.call(el, value);
    el.dispatchEvent(new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: value }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    el.dispatchEvent(new KeyboardEvent("keyup", { bubbles: true, key: "Unidentified" }));
    flash(el);
  }

  function flash(el) {
    const old = el.style.boxShadow;
    el.style.boxShadow = "0 0 0 2px #F2A541";
    setTimeout(() => { el.style.boxShadow = old; }, 700);
  }

  function fillCode(code, near) {
    const scope = near ? scopeOf(near) : document;
    const boxes = [...scope.querySelectorAll("input")].filter((i) => visible(i) && (isOTP(i) || (isTextual(i) && i.maxLength === 1)));
    const singles = boxes.filter((b) => b.maxLength === 1);
    if (singles.length >= code.length) { [...code].forEach((ch, i) => setValue(singles[i], ch)); return true; }
    const target = near && isOTP(near) ? near : boxes.find(isOTP);
    if (target) { setValue(target, code); return true; }
    return false;
  }

  function fill({ username, password, code, only }) {
    const field = active && active.isConnected ? active : document.activeElement;
    const scope = field instanceof HTMLElement ? scopeOf(field) : document;
    if (only === "code") { if (code) fillCode(code, field); closeMenu(); return; }
    const pws = passwordsIn(scope).length ? passwordsIn(scope) : passwordsIn(document);
    const current = pws.filter((p) => !isNewPassword(p));
    const pwTarget = isPassword(field) ? field : (current[0] || pws[0]);
    const userEl = isUsername(field) ? field : usernameFor(scope, pwTarget);
    if (only !== "password" && username && userEl) setValue(userEl, username);
    if (only !== "username" && password && pwTarget) setValue(pwTarget, password);
    if (code) setTimeout(() => fillCode(code), 50);
    closeMenu();
  }

  function fillGenerated(password) {
    lastGenerated = password;
    const field = active && active.isConnected ? active : document.activeElement;
    const scope = field instanceof HTMLElement ? scopeOf(field) : document;
    let targets = passwordsIn(scope).filter(isNewPassword);
    if (!targets.length) targets = passwordsIn(scope);
    targets.forEach((t) => setValue(t, password));   // fills both "password" and "confirm password"
    closeMenu();
  }

  // ---------- the in-field button ----------

  function showButton(el) {
    removeButton();
    const host = document.createElement("vault-button");
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;position:absolute;z-index:2147483646}
      button{all:unset;cursor:pointer;width:20px;height:20px;border-radius:50%;display:grid;place-items:center;background:#0B0C0E;box-shadow:0 0 0 1px #5C4320}
      button:hover{box-shadow:0 0 0 1.5px #F2A541}
      svg{display:block}
    </style><button title="Fill with Vault" aria-label="Fill with Vault"><svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
      <circle cx="6" cy="6" r="4.6" stroke="#F2A541" stroke-width="1.4"/><path d="M6 6 L6 2.6" stroke="#F2A541" stroke-width="1.4" stroke-linecap="round"/></svg></button>`;
    root.querySelector("button").addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); dismissed.delete(el); openMenu(el, true); });
    document.documentElement.appendChild(host);
    button = { host, el };
    place();
  }

  function removeButton() { button?.host.remove(); button = null; }

  function place() {
    if (button) {
      const r = button.el.getBoundingClientRect();
      if (!visible(button.el)) { removeButton(); }
      else {
        button.host.style.left = `${r.right + scrollX - 26}px`;
        button.host.style.top = `${r.top + scrollY + (r.height - 20) / 2}px`;
      }
    }
    if (menu && active) {
      const r = active.getBoundingClientRect();
      const w = 340;
      let left = Math.min(r.left, innerWidth - w - 8);
      left = Math.max(8, left);
      const below = r.bottom + 6;
      const h = parseInt(menu.frame.style.height) || 200;
      const top = below + h > innerHeight && r.top - h - 6 > 0 ? r.top - h - 6 : below;
      Object.assign(menu.frame.style, { left: `${left}px`, top: `${top}px` });
    }
  }

  // ---------- the menu (an extension page in a frame) ----------

  async function openMenu(el, forced) {
    const mode = modeOf(el);
    if (!mode) return;
    const startValue = el.value;
    if (!forced) {
      if (dismissed.has(el)) return;
      const info = await pageLogins();
      if (!info) return;
      const worth = mode === "new" || (mode === "otp" ? !!info.codeFor : info.count > 0 || !!info.lastPick);
      if (!worth) return;
    }
    if (menu && active === el) return;
    closeMenu();
    const r = await chrome.runtime.sendMessage({ type: "open-menu", mode }).catch(() => null);
    if (!r?.ok) return;
    if (!forced && (document.activeElement !== el || el.value !== startValue)) return;   // you already moved on or typed
    const frame = document.createElement("iframe");
    frame.src = `${EXT}menu.html#${r.token}`;
    frame.setAttribute("allowtransparency", "true");
    frame.setAttribute("title", "Vault");
    Object.assign(frame.style, {
      all: "initial", position: "fixed", zIndex: "2147483647", width: "340px", height: "120px", border: "0",
      borderRadius: "10px", boxShadow: "0 12px 32px rgba(0,0,0,.45)", colorScheme: "dark", background: "transparent",
    });
    document.documentElement.appendChild(frame);
    menu = { frame, token: r.token };
    active = el;
    place();
  }

  function closeMenu() { menu?.frame.remove(); menu = null; }

  async function pageLogins() {
    if (cache && Date.now() - cache.at < 15000) return cache.data;
    const r = await chrome.runtime.sendMessage({ type: "page-logins" }).catch(() => null);
    cache = { at: Date.now(), data: r?.ok ? r : null };
    return cache.data;
  }

  // Height changes and close requests from our own menu frame only.
  window.addEventListener("message", (e) => {
    if (!menu || e.source !== menu.frame.contentWindow || e.origin + "/" !== EXT) return;
    const d = e.data || {};
    if (d.vaultHeight) { menu.frame.style.height = `${Math.min(420, d.vaultHeight)}px`; place(); }
    if (d.vaultClose) { if (active) dismissed.add(active); closeMenu(); active?.focus(); }
  });

  // ---------- events ----------

  document.addEventListener("focusin", (e) => {
    const el = e.target;
    if (!(el instanceof HTMLInputElement) || !modeOf(el)) return;
    active = el;
    showButton(el);
    chrome.runtime.sendMessage({ type: "focus-frame" }).catch(() => {});
    openMenu(el, false);
  }, true);

  // Typing in the box, or moving to another part of the page, puts the menu away.
  document.addEventListener("input", (e) => { if (menu && e.isTrusted && e.target === active) closeMenu(); }, true);
  document.addEventListener("focusout", (e) => {
    if (menu && e.target === active && e.relatedTarget instanceof Element && e.relatedTarget !== menu.frame) closeMenu();
  }, true);

  document.addEventListener("mousedown", (e) => {
    if (!menu) return;
    if (e.target === menu.frame || e.target === active || e.target === button?.host) return;
    closeMenu();
  }, true);

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && menu) { if (active) dismissed.add(active); closeMenu(); }
    if (e.key === "Enter" && e.target instanceof HTMLInputElement && (isPassword(e.target) || isUsername(e.target))) capture(scopeOf(e.target), e.target);
  }, true);

  addEventListener("scroll", place, { passive: true, capture: true });
  addEventListener("resize", place, { passive: true });

  // ---------- noticing new sign-ins ----------

  let lastSent = { sig: "", at: 0 };

  function capture(scope, from) {
    setTimeout(() => {
      const pws = passwordsIn(scope).filter((p) => p.value);
      const fresh = pws.filter(isNewPassword);
      const pw = (fresh[0] || pws[0])?.value || "";
      const userEl = usernameFor(scope, fresh[0] || pws[0] || from);
      const username = userEl?.value?.trim() || "";
      if (!pw) {
        // Step one of a two-step sign-in (Gmail and others): remember the username for step two.
        if (username) chrome.runtime.sendMessage({ type: "typed-user", username }).catch(() => {});
        return;
      }
      const sig = username + "\u0000" + pw;
      if (sig === lastSent.sig && Date.now() - lastSent.at < 4000) return;
      lastSent = { sig, at: Date.now() };
      chrome.runtime.sendMessage({ type: "captured", username, password: pw }).catch(() => {});
    }, 0);
  }

  document.addEventListener("submit", (e) => { if (e.target instanceof HTMLFormElement) capture(e.target); }, true);
  document.addEventListener("click", (e) => {
    const b = e.target instanceof Element && e.target.closest("button,input[type=submit],input[type=button],[role=button],a");
    if (!b) return;
    const text = (b.textContent || b.value || b.getAttribute("aria-label") || "").trim();
    const scope = b.form || b.closest("form,[role=form],[role=dialog]") || document;
    const hasLogin = passwordsIn(scope).some((p) => p.value) || [...scope.querySelectorAll("input")].some((i) => visible(i) && isUsername(i) && i.value);
    if (hasLogin && (b.type === "submit" || /sign|log|continue|next|create|register|join|submit|save|start|verify|update|change/i.test(text))) capture(scope, b);
  }, true);

  // Keep the "show password" eye button from hiding a password box from us.
  new MutationObserver((list) => {
    for (const m of list) {
      if (m.type === "attributes" && m.target instanceof HTMLInputElement && m.oldValue === "password" && m.target.type !== "password") {
        m.target.dataset.vaultWasPassword = "1";
      }
    }
  }).observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ["type"], attributeOldValue: true });

  // ---------- save bar (top frame only) ----------

  let bar = null;
  function showSaveBar() {
    if (!isTop || bar) return;
    bar = document.createElement("iframe");
    bar.src = `${EXT}savebar.html`;
    bar.setAttribute("title", "Vault");
    Object.assign(bar.style, {
      all: "initial", position: "fixed", zIndex: "2147483647", top: "12px", right: "12px", width: "360px", height: "196px",
      border: "0", borderRadius: "10px", boxShadow: "0 12px 32px rgba(0,0,0,.45)", colorScheme: "dark",
    });
    document.documentElement.appendChild(bar);
  }
  function closeSaveBar() { bar?.remove(); bar = null; }

  // ---------- messages from the extension ----------

  chrome.runtime.onMessage.addListener((msg, sender) => {
    if (sender.id !== chrome.runtime.id) return;
    if (msg.type === "vault-fill") fill(msg);
    if (msg.type === "vault-generated") fillGenerated(msg.password);
    if (msg.type === "vault-menu-close") closeMenu();
    if (msg.type === "vault-offer") showSaveBar();
    if (msg.type === "vault-offer-close") closeSaveBar();
  });

  if (isTop) chrome.runtime.sendMessage({ type: "offer-pending" }).then((r) => { if (r?.ok) showSaveBar(); }).catch(() => {});

  // A login box that already has focus when the page loads.
  if (document.activeElement instanceof HTMLInputElement && modeOf(document.activeElement)) {
    active = document.activeElement; showButton(active); openMenu(active, false);
  }
})();
