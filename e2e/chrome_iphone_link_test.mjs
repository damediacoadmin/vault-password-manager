// End-to-end test: link Chrome to the iPhone by QR code. The Debug Mac app in test mode plays
// the iPhone (same ChromeLink code), against the real sync server, with throwaway test vaults.
// Run: CFT="<Chrome for Testing binary>" node e2e/chrome_iphone_link_test.mjs
import { chromium } from "playwright-core";
import { spawn, execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const EXT = `${ROOT}/chrome-extension`;
const APP = `${ROOT}/build/dd/Build/Products/Debug/Vault.app/Contents/MacOS/Vault`;
const CFT = process.env.CFT;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (n, ok, x = "") => results.push(`${ok ? "PASS" : "FAIL"}  ${n}${x ? "  " + x : ""}`);
const phone = (env) => execFileSync(APP, [], { env: { ...process.env, VAULT_TEST_MODE: "1", ...env }, timeout: 60000 }).toString();

check("test vault uploaded to sync", /UPLOADED/.test(phone({ VAULT_TEST_SYNC: "1" })));
const web = spawn("python3", ["-m", "http.server", "8766", "--bind", "127.0.0.1"], { cwd: `${ROOT}/e2e/site`, stdio: "ignore" });
const profile = fs.mkdtempSync(path.join(os.tmpdir(), "vault-profile-"));
const ctx = await chromium.launchPersistentContext(profile, {
  executablePath: CFT, headless: false, viewport: { width: 1100, height: 760 },
  args: ["--headless=new", `--disable-extensions-except=${EXT}`, `--load-extension=${EXT}`, "--host-resolver-rules=MAP *.test 127.0.0.1", "--no-first-run"],
});
const sw = ctx.serviceWorkers()[0] || await ctx.waitForEvent("serviceworker");
const extId = sw.url().split("/")[2];
const site = (p) => `http://login.example.test:8766/${p}`;
const menu = (pg) => pg.frameLocator('iframe[src*="menu.html"]');
const unlockBtn = "button:has-text('Unlock'):not(:has-text('iPhone'))";

try {
  const pop = await ctx.newPage();
  await pop.setViewportSize({ width: 360, height: 580 });
  await pop.goto(`chrome-extension://${extId}/popup.html`);
  await pop.click("text=Link with iPhone");
  await pop.waitForSelector(".qr[data-link]");
  const link = await pop.getAttribute(".qr", "data-link");
  check("extension shows a link QR code", /^vault-link:[0-9a-f]{32}\.[A-Za-z0-9_-]{87}$/.test(link));
  check("iPhone side reads the QR and sends the sealed key", /LINKED/.test(phone({ VAULT_TEST_LINK: link })));
  await pop.waitForSelector("nav", { timeout: 15000 });
  check("Chrome linked, synced and unlocked", (await pop.textContent("#state")) === "Unlocked");
  check("vault key is not on disk", !JSON.stringify(await sw.evaluate(() => chrome.storage.local.get(null))).includes("lkey"));

  const page = await ctx.newPage();
  await page.goto(site("login.html")); await page.click("#u");
  await menu(page).locator(".row", { hasText: "Example work" }).click(); await sleep(500);
  check("fills from the synced vault", (await page.inputValue("#p")) === "quartz-Ember-3-saddle-river");

  await page.goto(site("signup.html")); await page.click("#p1");
  await menu(page).locator(".row", { hasText: "strong password" }).click(); await sleep(400);
  const p1 = await page.inputValue("#p1");
  await page.fill("#u", "chrome-new@example.com");
  await page.click("button:has-text('Create account')"); await page.waitForURL(/welcome/);
  const bar = page.frameLocator('iframe[src*="savebar.html"]');
  await bar.locator("#title", { hasText: "Save your" }).waitFor({ timeout: 8000 });
  await bar.locator("#save").click(); await sleep(2000);
  const dump = phone({ VAULT_TEST_PULL: "1" });
  check("saved login reached the iPhone through sync", dump.includes(`ITEM Example | chrome-new@example.com | ${p1} | 0`));
  check("Chrome listed as a synced device", /DEVICE Chrome Chrome/.test(dump));

  await page.goto(site("login.html"));
  await page.fill("#u", "work@example.com"); await page.fill("#p", "brand-New-Secret-42");
  await page.click("button:has-text('Log in')"); await page.waitForURL(/welcome/);
  await bar.locator("#title", { hasText: "Update" }).waitFor({ timeout: 8000 });
  await bar.locator("#save").click(); await sleep(2000);
  check("password update synced, old one kept in history", phone({ VAULT_TEST_PULL: "1" }).includes("ITEM Example work | work@example.com | brand-New-Secret-42 | 1"));

  await pop.reload(); await pop.waitForSelector("nav");
  await pop.click("footer button.caps"); await pop.waitForSelector("text=Unlock with iPhone");
  await pop.fill("input[type=password]", "wrong-password-123"); await pop.click(unlockBtn);
  await pop.waitForSelector("p.red", { timeout: 20000 });
  check("wrong master password refused", (await pop.textContent("p.red")).includes("Wrong"));
  await pop.fill("input[type=password]", "test-only-not-real-0"); await pop.click(unlockBtn);
  await pop.waitForSelector("nav", { timeout: 20000 }).then(() => check("unlocks with the master password", true), () => check("unlocks with the master password", false));

  await pop.click("footer button.caps"); await pop.click("text=Unlock with iPhone");
  await pop.waitForSelector(".qr[data-link]");
  phone({ VAULT_TEST_LINK: await pop.getAttribute(".qr", "data-link") });
  await pop.waitForSelector("nav", { timeout: 15000 }).then(() => check("unlocks again by scanning with iPhone", true), () => check("unlocks again by scanning with iPhone", false));

  await pop.click("nav >> text=Search"); await pop.fill("main input.field", "other"); await sleep(500);
  await pop.click(".row >> button[title='Copy password']");
  await pop.waitForSelector("text=Different site", { timeout: 5000 }).then(() => check("other-site password asks for master password", true), () => check("other-site password asks for master password", false));
} catch (e) { check("no unexpected error", false, String(e).slice(0, 300)); }

await ctx.close(); web.kill();
fs.rmSync(profile, { recursive: true, force: true });
console.log(results.join("\n"));
process.exit(results.every((r) => r.startsWith("PASS")) ? 0 : 1);
