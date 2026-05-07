# Check Point VPN auto-login for macOS

One-shot CLI login to Check Point Endpoint Security VPN — no GUI clicks, no manual OTP typing. Uses the `trac` CLI bundled with Check Point + macOS Keychain for credential storage.

Designed for setups using **challenge-response** auth: LDAP password + TOTP from an authenticator app (Google Authenticator, Authy, ADSelfService Plus, etc.).

## Why

If your corporate VPN expires every N hours and forces you to re-type LDAP password + a 6-digit TOTP code every time, this fully automates that login. Including auto-reconnect when the session expires.

## What it does

- Stores LDAP password and TOTP secret in macOS Keychain (never plaintext on disk)
- Generates the current TOTP code on demand from the stored secret
- Drives Check Point's `trac` CLI with `expect` to answer the OTP challenge prompt
- Optional LaunchAgent re-runs every 2 minutes — auto-reconnects when session expires
- `vpn-pause` / `vpn-resume` to temporarily disable auto-reconnect (e.g., when at home / on a personal network)

## Disclaimer

> **Read your company's IT policy before using this.** Some organizations forbid exporting TOTP secrets from MFA apps, even for personal automation on a corporate device. Using this may violate your acceptable-use policy. You are responsible for that decision.

> The TOTP secret is sensitive. Anyone who has it can generate codes for your VPN account indefinitely (until your admin rotates the seed). Treat it like a long-term credential. This tool stores it in macOS Keychain, gated by your login password — same security posture as Safari's password manager.

## Prerequisites

- macOS (tested on Sonoma; should work on Big Sur+)
- Check Point Endpoint Security VPN installed (the standard client at `/Applications/Endpoint Security VPN.app`)
- Homebrew
- Your TOTP secret in **base32** form (see [Extracting the TOTP secret](#extracting-the-totp-secret) below)

## Install

```bash
git clone https://github.com/<you>/checkpoint-vpn-autologin-macos.git
cd checkpoint-vpn-autologin-macos

brew install oath-toolkit
brew install zbar     # only needed if using --qr to extract from a QR image

./install.sh                              # interactive: prompts for everything
# OR
./install.sh --qr ~/Downloads/myqr.png    # auto-extract TOTP from a Google Authenticator export QR
```

The installer:
- Prompts for VPN site (e.g., `vpn.example.com`), username, password, TOTP secret
- Stores them in Keychain under services `checkpoint-vpn-{site,user,pass,totp}` (account=`default`)
- Copies `vpn-connect`, `vpn-pause`, `vpn-resume` to `~/bin/`
- Adds `~/bin` to PATH in `~/.zshrc`
- Installs and loads a LaunchAgent for auto-reconnect every 2 minutes

## Usage

```bash
vpn-connect    # connect (idempotent — no-op if already connected)
vpn-pause      # disable auto-reconnect
vpn-resume     # re-enable auto-reconnect
tail -f ~/.vpn-connect.log    # debug
```

## Hotkey (optional)

Use [Shortcuts.app](https://support.apple.com/guide/shortcuts-mac/) (built into macOS):

1. Open Shortcuts.app → **⌘N**
2. Drag in **Run Shell Script** action
3. Set script to `~/bin/vpn-connect`, Shell: `zsh`
4. Name it "Connect VPN"
5. Click **(i)** → **Add Keyboard Shortcut** → press your combo
6. **Don't tick "Use as Quick Action"** — that couples the hotkey to selection context and breaks global firing

If Shortcuts.app's hotkey doesn't fire reliably on your machine (a known macOS quirk), install [skhd](https://github.com/koekeishiya/skhd) instead — bulletproof, two-line config.

## Extracting the TOTP secret

Your authenticator app generates 6-digit codes from a shared secret. To automate the codes, you need that secret in **base32**.

### From Google Authenticator

1. Open Google Authenticator on your phone
2. Menu → **Transfer accounts** → **Export accounts**
3. Select **only your VPN/MFA entry** (do not export others — they'll be exposed in the same QR)
4. Tap **Next** — it shows a QR code
5. Screenshot the QR, AirDrop to your Mac
6. Pass the screenshot path to the installer with `--qr`:
   ```bash
   ./install.sh --qr ~/Downloads/qr-screenshot.png
   ```
7. **Delete the screenshot** from your phone and Mac immediately after install. The QR is permanent compromise of your TOTP if it leaks.

### From Authy / 1Password / other apps

Some authenticator apps (Authy, 1Password TOTP) let you view the raw secret directly. Look for "Show secret" or "Copy secret". Paste into the installer when prompted.

### From original setup

If you saved the QR or text key when you first set up MFA, you can use that. Some companies' MFA portals also let you re-register MFA, which gives you a fresh QR.

## How the auth flow works

The site is configured for challenge-response: `trac` issues the LDAP password, server then prompts:

```
Challenge Enter the time-based OTP generated in Google Authenticator.: 
```

The script uses `expect` to watch for that prompt and feed the freshly-generated TOTP. Concatenated `password+OTP` (typical for some RADIUS+TOTP setups) does **not** work for this auth method — the script doesn't try it.

If your VPN uses concatenated auth instead, the prompt regex in `vpn-connect` won't match and the script will fail with a timeout. You'd need to modify the connect command to use `-p "${PASS}${OTP}"` directly. PRs welcome.

## Files

| File | Purpose |
|---|---|
| `install.sh` | One-time setup — keychain, scripts, LaunchAgent |
| `bin/vpn-connect` | The connect script (idempotent) |
| `bin/vpn-pause` / `bin/vpn-resume` | Toggle auto-reconnect |
| `launchd/com.user.vpn-keepalive.plist` | LaunchAgent template |

## Troubleshooting

**`vpn-connect` exits with `oathtool not installed`**
→ `brew install oath-toolkit`

**`vpn-connect` exits with `trac CLI missing`**
→ Check Point Endpoint Security VPN isn't installed, or is in a non-standard path. Verify `/Applications/Endpoint Security VPN.app` exists.

**Connect works manually but auto-reconnect doesn't fire**
→ Check `launchctl list | grep vpn-keepalive` — should show your job. Check `~/.vpn-keepalive.stderr.log` for errors. Verify `~/.vpn-disabled` does not exist (that's the pause flag).

**OTP is rejected**
→ Time on your Mac is drifting. Compare `oathtool --totp -b "$(security find-generic-password -s checkpoint-vpn-totp -a default -w)"` against your phone right now. If they differ, check `sudo sntp -sS time.apple.com`.

**Password is rejected**
→ Your AD password rotated. Re-stash with:
  ```bash
  read -s "p?VPN password: " && \
    security add-generic-password -s checkpoint-vpn-pass -a default -w "$p" -U && \
    unset p
  ```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.*.vpn-keepalive.plist
rm ~/Library/LaunchAgents/com.*.vpn-keepalive.plist
rm ~/bin/vpn-connect ~/bin/vpn-pause ~/bin/vpn-resume
for s in checkpoint-vpn-site checkpoint-vpn-user checkpoint-vpn-pass checkpoint-vpn-totp; do
  security delete-generic-password -s "$s" -a default 2>/dev/null
done
```

## License

MIT — see [LICENSE](LICENSE).

## Contributing

This was built to scratch a personal itch. PRs welcome for:
- Other auth flow variants (RADIUS-concatenated, SecurID PIN+passcode, certificate)
- Other macOS quirks (Sequoia/Tahoe behavior changes)
- Linux / Windows ports

No CI, no test suite — this is a small shell project. Keep it simple.
