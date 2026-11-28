# End-to-end tests

All tests use a throwaway test vault (Debug build, `VAULT_TEST_MODE=1`, separate Keychain
namespace and socket folder). They never read or change a real vault.

Build first: `xcodebuild -project Vault.xcodeproj -scheme VaultMac -configuration Debug -derivedDataPath build/dd build`

- `python3 e2e/ai_agent_test.py`: the AI agent connection (vault-mcp over MCP to the Mac app):
  approve, deny, Touch ID failure, never-share logins, 15-minute window, hourly cap, socket checks.
- `VAULT_TEST_MODE=1 CFT=<Chrome for Testing binary> node e2e/chrome_mac_test.mjs`: Chrome
  extension through the Mac app: pairing, fill, generate, save, update, two-step sign-in, 2FA, lock.
- `CFT=<Chrome for Testing binary> node e2e/chrome_iphone_link_test.mjs`: link Chrome by QR code
  (the Debug Mac app plays the iPhone) against your sync server: sync both ways, lock, unlock.

The Chrome tests need `playwright-core` on `NODE_PATH` and Chrome for Testing
(https://googlechromelabs.github.io/chrome-for-testing/). Afterwards, wipe the test vault with
`VAULT_TEST_MODE=1 VAULT_TEST_CLEANUP=1 build/dd/Build/Products/Debug/Vault.app/Contents/MacOS/Vault`.
