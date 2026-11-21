# Vault

A zero-knowledge password manager for iPhone and Mac, built with SwiftUI.

Every item is encrypted on the device with AES-256-GCM. The vault key is wrapped by a Secure Enclave key that needs Face ID or Touch ID, by your master password (PBKDF2, 650,000 rounds), and by a one-time recovery code. Nothing readable ever leaves the device.

## Features

- Logins, passkeys, one-time codes (TOTP), cards, bank accounts, IDs, secure notes, personal info
- AutoFill on iPhone and Mac (passwords, passkeys, one-time codes), exact-site matching against look-alike domains
- Password generator (words or characters) and Password Health (weak, reused, old, breached via k-anonymity)
- Import from Dashlane (CSV/zip read in memory) and from any app that supports Apple's Credential Exchange
- QR scanner to move two-factor accounts from apps without export (for example Authy)
- End-to-end encrypted sync through a small Cloudflare Worker that only stores ciphertext
- Favorites, auto-lock, lockout after repeated wrong master passwords, third-party keyboards blocked on iPhone
- Optional AI assistant access on Mac through a local MCP helper: one login per request, Touch ID each time, audit log, no list or export

## Security model

| Threat | Protection |
| --- | --- |
| Stolen locked device | Vault and key envelope live in the data protection Keychain, this device only. The Secure Enclave key needs your current biometrics. |
| Guessing the master password | PBKDF2-SHA256 with 650,000 rounds plus a lockout (30 s up to 15 min after 5 wrong tries). |
| Compromised sync server | Server stores only AES-GCM ciphertext. Vault ID and server token are derived from the vault key. |
| Phishing | AutoFill offers logins only for the same registrable domain. |
| Rogue local process asking the AI bridge | Unix socket (0600) accepts only the helper signed by the same team, verified by code signature. Every request needs a click plus Touch ID. |

Not covered: an attacker with your unlocked device and your biometrics, or malware with full control of your Mac.

## Build

Requirements: Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

1. `cp local.example.yml local.yml` and set your team ID and, if you want sync, your sync URL.
2. `xcodegen generate`
3. Open `Vault.xcodeproj` and run the `Vault` (iOS) or `VaultMac` scheme. Tests: `xcodebuild test -scheme Vault -destination 'platform=iOS Simulator,name=<device>'`.

Bundle IDs use `com.damediaco.*`. Change them in `project.yml`, the entitlements, and `Shared/Crypto.swift` (Keychain service and access group) for your own builds.

### Sync server (optional)

`sync-worker/` is a Cloudflare Worker with a SQLite Durable Object. Copy `wrangler.jsonc` to `wrangler.local.jsonc`, set `account_id` and your route, then `npx wrangler deploy -c wrangler.local.jsonc`.

### AI assistant (optional, Mac)

The Mac app ships `vault-mcp` in `Vault.app/Contents/MacOS/`. Register it with Claude Code:

```
claude mcp add -s user vault -- /Applications/Vault.app/Contents/MacOS/vault-mcp
```

## License

MIT, see [LICENSE](LICENSE). Third-party material is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
