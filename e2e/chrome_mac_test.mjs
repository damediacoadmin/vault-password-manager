// End-to-end test: Chrome extension through the Vault Mac app (native messaging), with a
// throwaway test vault (Debug build, VAULT_TEST_MODE=1). Never touches the real vault.
// Run: VAULT_TEST_MODE=1 CFT="<Chrome for Testing binary>" node e2e/chrome_mac_test.mjs
// Needs playwright-core installed somewhere on NODE_PATH.
import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const EXT = `${ROOT}/chrome-extension`;
const APP = `${ROOT}/build/dd/Build/Products/Debug/Vault.app/Contents/MacOS/Vault`;
const CFT = process.env.CFT;
const SOCK = path.join(os.homedir(), "Library/Application Support/Vault/Test/browser.sock");
const HOSTFILE = path.join(os.homedir(), "Library/Application Support/Google/Chrome for Testing/NativeMessagingHosts/com.damediaco.vault.json");
const shots = process.env.SHOTS || fs.mkdtempSync(path.join(os.tmpdir(), "vault-shots-"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = [];
const check = (n, ok, x = "") => results.push(`${ok ? "PASS" : "FAIL"}  ${n}${x ? "  " + x : ""}`);

const web = spawn("python3", ["-m", "http.server", "8765", "--bind", "127.0.0.1"], { cwd: `${ROOT}/e2e/site`, stdio: "ignore" });
try { fs.unlinkSync(SOCK); } catch {}
const app = spawn(APP, [], { env: { ...process.env, VAULT_TEST_MODE: "1", VAULT_TEST_APPROVE: "1" }, stdio: "ignore" });
for (let i = 0; i < 40 && !fs.existsSync(SOCK); i++) await sleep(250);
check("test Vault app started", fs.existsSync(SOCK));

const profile = fs.mkdtempSync(path.join(os.tmpdir(), "vault-profile-"));
fs.mkdirSync(`${profile}/NativeMessagingHosts`, { recursive: true });
fs.copyFileSync(HOSTFILE, `${profile}/NativeMessagingHosts/com.damediaco.vault.json`);
const ctx = await chromium.launchPersistentContext(profile, {
  executablePath: CFT, headless: false, viewport: { width: 1100, height: 760 },
  args: ["--headless=new", `--disable-extensions-except=${EXT}`, `--load-extension=${EXT}`, "--host-resolver-rules=MAP *.test 127.0.0.1", "--no-first-run"],
});
const sw = ctx.serviceWorkers()[0] || await ctx.waitForEvent("serviceworker", { timeout: 10000 });
const extId = sw.url().split("/")[2];
check("extension loaded with its fixed ID", extId === "cmjgeknhijfgeipkkclkdnmblamegcpm", extId);
const site = (p, host = "login.example.test") => `http://${host}:8765/${p}`;
const menu = (pg) => pg.frameLocator('iframe[src*="menu.html"]');
const row = (pg, t) => menu(pg).locator(".row", { hasText: t }).first();
let page;

try {
  const pop = await ctx.newPage();
  await pop.setViewportSize({ width: 360, height: 580 });
  await pop.goto(`chrome-extension://${extId}/popup.html`);
  await pop.click("text=Use Vault on this Mac instead");
  await pop.waitForSelector(".pair");
  check("pairing code shown", /^\d{3} \d{3}$/.test((await pop.textContent(".pair")).trim()));
  await pop.click("text=Connect to Vault on this Mac");
  await pop.waitForSelector("nav", { timeout: 10000 });
  check("paired with the Mac app and unlocked", (await pop.textContent("#state")) === "Unlocked");

  page = await ctx.newPage();
  await page.goto(site("login.html"));
  await page.click("#u");
  await row(page, "Example").waitFor({ timeout: 8000 });
  const names = await menu(page).locator(".row .t").allTextContents();
  check("menu lists only this site's logins", names.length === 2 && !names.includes("Other site"), names.join(", "));
  check("page cannot read inside the menu", await page.evaluate(() => { try { return document.querySelector('iframe[src*="menu.html"]').contentDocument === null; } catch { return true; } }));
  await row(page, "Example work").click();
  await page.waitForFunction(() => document.querySelector("#p").value.length > 0, null, { timeout: 3000 }).catch(() => {});
  check("fills username and password", (await page.inputValue("#u")) === "work@example.com" && (await page.inputValue("#p")) === "quartz-Ember-3-saddle-river");

  await page.goto(site("signup.html"));
  await page.click("#p1");
  await row(page, "strong password").click(); await sleep(500);
  const p1 = await page.inputValue("#p1");
  check("generated password fills both boxes", p1.length >= 16 && p1 === (await page.inputValue("#p2")));
  await page.fill("#u", "new@example.com");
  await page.click("button:has-text('Create account')");
  await page.waitForURL(/welcome/);
  const bar = page.frameLocator('iframe[src*="savebar.html"]');
  await bar.locator("#title", { hasText: "Save your" }).waitFor({ timeout: 8000 });
  check("offers to save after sign-up", (await bar.locator("#user").inputValue()) === "new@example.com");
  await bar.locator("#save").click(); await sleep(600);
  await page.goto(site("login.html")); await page.click("#u");
  await row(page, "new@example.com").waitFor({ timeout: 8000 }).then(() => check("new login saved to Vault", true), () => check("new login saved to Vault", false));
  await page.keyboard.press("Escape");

  await page.fill("#u", "work@example.com"); await page.fill("#p", "brand-New-Secret-42");
  await page.click("button:has-text('Log in')"); await page.waitForURL(/welcome/);
  await bar.locator("#title", { hasText: "Update" }).waitFor({ timeout: 8000 }).then(() => check("offers to update a changed password", true), () => check("offers to update a changed password", false));
  await bar.locator("#save").click(); await sleep(500);

  await page.goto(site("step1.html")); await page.click("#u");
  await row(page, "dave@example.com").click(); await sleep(400);
  check("two-step sign-in: step 1 fills the username", (await page.inputValue("#u")) === "dave@example.com");
  await page.click("text=Next"); await page.waitForURL(/step2/);
  await page.click("#p");
  await menu(page).locator(".tag").waitFor({ timeout: 8000 }).then(() => check("step 2 offers Continue on the same login", true), () => check("step 2 offers Continue on the same login", false));
  await menu(page).locator(".row").first().click(); await sleep(400);
  check("step 2 fills the password in one click", (await page.inputValue("#p")) === "harbor-Tangle-7-velvet-Orbit");
  await page.click("text=Next"); await page.waitForURL(/otp/);
  await page.click("#c");
  await menu(page).locator(".code").waitFor({ timeout: 8000 });
  await menu(page).locator(".row").first().click(); await sleep(400);
  check("fills the 2FA code", /^\d{6}$/.test(await page.inputValue("#c")));

  await page.goto(site("login.html", "other.test")); await page.click("#u");
  await row(page, "Other site").waitFor({ timeout: 8000 });
  check("other site gets only its own login", (await menu(page).locator(".row .t").allTextContents()).length === 1);

  await pop.reload(); await pop.waitForSelector("nav");
  await pop.click("nav >> text=Search"); await pop.fill("main input.field", "example"); await sleep(500);
  check("popup search works", (await pop.locator(".row").count()) >= 3);
  await pop.click("nav >> text=Generate"); await pop.waitForSelector(".gen"); await sleep(400);
  check("popup generator works", ((await pop.textContent(".gen")) || "").length >= 16);
  await pop.click("footer button.caps"); await pop.waitForSelector("text=Unlock with Touch ID");
  await page.goto(site("login.html")); await page.click("#u"); await sleep(1200);
  check("nothing shows while Vault is locked", (await page.locator('iframe[src*="menu.html"]').count()) === 0);
} catch (e) { check("no unexpected error", false, String(e).slice(0, 300)); await page?.screenshot({ path: `${shots}/mac-error.png` }).catch(() => {}); }

await ctx.close(); app.kill(); web.kill();
fs.rmSync(profile, { recursive: true, force: true });
console.log(results.join("\n"));
process.exit(results.every((r) => r.startsWith("PASS")) ? 0 : 1);
