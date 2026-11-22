# Vault

A zero-knowledge password manager for iPhone, Mac and Chrome. The apps are native SwiftUI; the Chrome extension is plain Manifest V3 JavaScript with no dependencies beyond a bundled QR library.

Every item is encrypted on the device with AES-256-GCM. The vault key is wrapped by a Secure Enclave key that needs Face ID or Touch ID, by your master password (PBKDF2, 650,000 rounds), and by a one-time recovery code. Nothing readable ever leaves the device.

## Features

- Logins, passkeys, one-time codes (TOTP), cards, bank accounts, IDs, secure notes, personal info
- AutoFill on iPhone and Mac (passwords, passkeys, one-time codes), exact-site matching against look-alike domains
- Password generator (words or characters) and Password Health (weak, reused, old, breached via k-anonymity)
- Import from Dashlane (CSV/zip read in memory) and from any app that supports Apple's Credential Exchange
- QR scanner to move two-factor accounts from apps without export (for example Authy)
- End-to-end encrypted sync through a small Cloudflare Worker that only stores ciphertext
- Favorites, auto-lock, lockout after repeated wrong master passwords, third-party keyboards blocked on iPhone
- Create a login straight from AutoFill during sign-up: app name, one-tap usernames from your own list, generated password (iOS 26.2 save and generate requests supported)
- Chrome extension: fill from a menu under the login box, save new logins, update changed passwords, generate passwords that fill both boxes, two-step sign-ins, 2FA codes
- Link Chrome to your iPhone by QR code (Face ID on the phone); Chrome then keeps its own end-to-end encrypted copy, or it can use the Mac app instead
- Optional AI assistant access on Mac through a local MCP helper: one login per request, Touch ID each time, audit log, no list or export

## Security model

| Threat | Protection |
| --- | --- |
| Stolen locked device | Vault and key envelope live in the data protection Keychain, this device only. The Secure Enclave key needs your current biometrics. |
| Guessing the master password | PBKDF2-SHA256 with 650,000 rounds plus a lockout (30 s up to 15 min after 5 wrong tries). |
| Compromised sync server | Server stores only AES-GCM ciphertext. Vault ID and server token are derived from the vault key. |
| Phishing | AutoFill offers logins only for the same registrable domain. |
| Chrome extension (linked to iPhone) | The vault key arrives sealed to a one-time browser key (ECDH P-256, HKDF, AES-GCM) through a write-once, read-once server channel. It is kept only in Chrome's in-memory session storage, never on disk, and dropped after 30 idle minutes, on Mac lock, or when Chrome quits. Logins for other sites need the master password. The login list is drawn in an extension frame the page cannot read. |
| Chrome extension (through the Mac app) | Native messaging helper signed by the same team checks that Google Chrome started it; each browser is paired once with a matching code and Touch ID; other-site fills need Touch ID. |
| Rogue local process asking the AI bridge | Unix socket (0600) accepts only the helper signed by the same team, verified by code signature. Every request needs a click plus Touch ID. |

Not covered: an attacker with your unlocked device and your biometrics, or malware with full control of your Mac.

## Build

Step-by-step setup, from clone to iPhone, Mac and Chrome with your own sync server: [SETUP.md](SETUP.md). Short version:

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. `cp local.example.yml local.yml` and set your team ID and, if you want sync, your sync URL.
2. `xcodegen generate`
3. Open `Vault.xcodeproj` and run the `Vault` (iOS) or `VaultMac` scheme. Tests: `xcodebuild test -scheme Vault -destination 'platform=iOS Simulator,name=<device>'`.

Bundle IDs use `com.damediaco.*`. Change them in `project.yml`, the entitlements, and `Shared/Crypto.swift` (Keychain service and access group) for your own builds.

### Sync server (optional)

`sync-worker/` is a Cloudflare Worker with a SQLite Durable Object. Copy `wrangler.jsonc` to `wrangler.local.jsonc`, set `account_id` and your route, then `npx wrangler deploy -c wrangler.local.jsonc`.

### Chrome extension

See [chrome-extension/README.md](chrome-extension/README.md). Set your sync server URL in `chrome-extension/local.js` (`SYNC`) and in `host_permissions` in `chrome-extension/manifest.json`, then load the folder unpacked in `chrome://extensions`. For the Mac app bridge, also put your own extension ID in `Browser/main.swift` and `Mac/BrowserBroker.swift` (or keep the `key` in the manifest).

### AI assistant (optional, Mac)

The Mac app ships `vault-mcp` in `Vault.app/Contents/MacOS/`. Register it with Claude Code:

```
claude mcp add -s user vault -- /Applications/Vault.app/Contents/MacOS/vault-mcp
```

## License

MIT, see [LICENSE](LICENSE). Third-party material is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
