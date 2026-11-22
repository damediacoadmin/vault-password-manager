# Setting up Vault from scratch

This guide takes you from a fresh clone to Vault running on your iPhone, your Mac and Chrome,
with your own private sync server. Plan on about an hour the first time.

## Let your AI assistant do it

Using a coding assistant that can run commands on your Mac (Claude Code, Codex, Cursor and similar)?
Paste this prompt and it will walk through every step below with you:

```
Set up Vault, the open source password manager at
https://github.com/damediacoadmin/vault-password-manager, for me on this Mac.
Follow SETUP.md in that repo step by step.

1. Check my Mac first: Xcode 26 or later, Homebrew, xcodegen, node. Install what is missing with
   Homebrew, and tell me before you install anything.
2. Clone the repo and replace the com.damediaco bundle prefix with com.<my name>
   (ask me what to use).
3. Ask me for my Apple Developer team ID and the domain on my Cloudflare account to use for sync.
   Deploy sync-worker with wrangler (I will log in to Cloudflare in the browser when asked).
   Check that https://<domain>/vault-sync/link/00000000000000000000000000000000 answers 404.
4. Create local.yml from local.example.yml, run xcodegen, and build the VaultMac scheme.
   Install it in /Applications. Then build the Vault scheme for my iPhone (ask me to connect it).
5. Set the sync URL in chrome-extension/local.js and chrome-extension/manifest.json, then tell me
   exactly how to load the extension in chrome://extensions and link it with my iPhone.
6. Finish with the steps only I can do: create the vault and write down the recovery code,
   turn on AutoFill on iPhone and Mac, and import from Dashlane.

Rules: never ask me for my master password, recovery code or any saved password, and never
print them. Do not paste my passwords into chat or logs. Stop and ask before anything that
costs money.
```

## What you need

- A Mac with Xcode 26 or later
- A paid Apple Developer Program membership (AutoFill password providers need it)
- [Homebrew](https://brew.sh), then `brew install xcodegen node`
- A Cloudflare account with a domain on it (for sync; the free plan is enough)
- Google Chrome (for the extension)

## 1. Get the code

```
git clone https://github.com/damediacoadmin/vault-password-manager.git
cd vault-password-manager
```

## 2. Use your own app IDs

Bundle IDs start with `com.damediaco`. Replace that with your own prefix everywhere:

```
grep -rl "com.damediaco" --exclude-dir=.git . | xargs sed -i '' 's/com\.damediaco/com.yourname/g'
```

## 3. Deploy your sync server

```
cd sync-worker
cp wrangler.jsonc wrangler.local.jsonc
```

In `wrangler.local.jsonc`, add `"account_id": "<your Cloudflare account ID>"` and change both
`your-domain.example` values to your domain. Then:

```
npx wrangler login
npx wrangler deploy -c wrangler.local.jsonc
cd ..
```

Your sync URL is now `https://<your domain>/vault-sync/`. The server only ever stores encrypted data.

## 4. Point the apps at it

```
cp local.example.yml local.yml
```

In `local.yml`, set `DEVELOPMENT_TEAM` to your Apple team ID (Xcode, Settings, Accounts) and
`VAULT_SYNC_URL` to `https://<your domain>/vault-sync/v/` (note the `/v/` at the end).

## 5. Build and run

```
xcodegen generate
open Vault.xcodeproj
```

- iPhone: pick the `Vault` scheme and your iPhone, then Run.
- Mac: pick the `VaultMac` scheme and My Mac, then Run. Move the built app to /Applications for daily use.

Let Xcode manage signing when it asks. Then create your vault on one device, write down the
recovery code, turn on Sync in Settings, and on the other device choose Join a vault and scan its QR code.

## 6. Turn on AutoFill

- iPhone: Settings, General, AutoFill and Passwords, turn on Vault.
- Mac: System Settings, General, AutoFill and Passwords, turn on Vault.

## 7. Chrome extension

1. In `chrome-extension/local.js`, set `SYNC` to `https://<your domain>/vault-sync/`.
2. In `chrome-extension/manifest.json`, set `host_permissions` to `https://<your domain>/vault-sync/*`.
3. In Chrome, open `chrome://extensions`, turn on Developer mode, click Load unpacked, and pick the `chrome-extension` folder.
4. Click the Vault button in Chrome's toolbar, then Link with iPhone. On the iPhone, open Vault, Settings, Link Chrome, scan the code and confirm with Face ID.

Prefer Chrome to use the Mac app instead? Choose Use Vault on this Mac. Keep the `key` in
`manifest.json` so the extension ID matches the one in `Browser/main.swift` and `Mac/BrowserBroker.swift`.
If you remove or replace it, put your new extension ID in both files.

## 8. Move in from Dashlane

On dashlane.com, open Settings, then Export data, then Export to CSV. In Vault on the Mac,
open Settings and choose the exported .zip. Two-factor accounts from apps like Authy move one at a time:
turn 2FA off and on again on each site and scan the new QR code into the login in Vault.

## 9. Optional: let Claude look up a login

```
claude mcp add -s user vault -- /Applications/Vault.app/Contents/MacOS/vault-mcp
```

Each request shows a card on the Mac and needs Touch ID.

## Good to know

- There is no password reset. Keep the recovery code on paper.
- Vault has not had an independent security audit yet.
- Run the tests with `xcodebuild test -scheme Vault -destination 'platform=iOS Simulator,name=<simulator>'`.
