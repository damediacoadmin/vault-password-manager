# Vault for Chrome

Fills, saves and generates passwords and 2FA codes in Google Chrome, using the Vault app on
your Mac. The extension never stores passwords. It talks to Vault through a signed helper
(`vault-chrome`, inside Vault.app) using Chrome native messaging.

## Two ways to connect
- **Link with iPhone (recommended):** click Link with iPhone in the extension, then in Vault on the
  iPhone open Settings, Link Chrome, and scan the QR code. Chrome keeps its own end-to-end
  encrypted copy of the vault in sync and does not need the Mac app.
- **Use Vault on this Mac:** the steps below.

## Use Vault on this Mac
1. Open Vault on your Mac once (it tells Chrome where the helper is).
2. In Chrome go to `chrome://extensions`, switch on Developer mode, click **Load unpacked**
   and choose this `chrome-extension` folder.
3. Click the Vault button in Chrome's toolbar, then **Connect to Vault**. Check the code
   matches the card on your Mac, click Connect and use Touch ID.

## How it stays safe
- Only Google Chrome (checked by code signature) running this extension (fixed ID
  `cmjgeknhijfgeipkkclkdnmblamegcpm`) can start the helper, and only the signed helper can
  reach Vault's private socket.
- Each browser is paired once with a matching code and Touch ID; every request carries the
  pairing key, which Vault checks against a stored hash.
- Chrome only sees names and usernames for the site you are on. Filling or copying a login
  saved for a different site needs Touch ID, so look-alike sites get nothing.
- The site address always comes from Chrome, never from the page. The login list is drawn in
  an extension frame the page cannot read.
- No list, export or dump command exists.
