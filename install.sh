#!/bin/zsh
# install.sh — set up Check Point VPN auto-login on macOS.
# Idempotent: safe to re-run.
#
# Usage:
#   ./install.sh                     # interactive: prompts for everything
#   ./install.sh --qr <path-to-png>  # auto-extract TOTP secret from a Google Authenticator export QR
#
# What it does:
#   1. Checks dependencies (oath-toolkit, expect, optionally zbar)
#   2. Verifies Check Point Endpoint Security VPN is installed
#   3. Prompts for VPN site, username, password, and TOTP secret (or extracts from QR)
#   4. Stashes all 4 in macOS Keychain
#   5. Installs vpn-connect / vpn-pause / vpn-resume to ~/bin/
#   6. Adds ~/bin to PATH in ~/.zshrc
#   7. Installs and loads LaunchAgent for auto-reconnect every 2 minutes

set -e
SCRIPT_DIR="${0:A:h}"
QR_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qr) QR_PATH="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac
done

bold() { print -P "%B$*%b"; }
ok()   { print -P "  %F{green}OK%f $*"; }
err()  { print -P "  %F{red}ERR%f $*" >&2; }
warn() { print -P "  %F{yellow}WARN%f $*"; }

# --- Platform check ---
[[ "$(uname -s)" == "Darwin" ]] || { err "macOS only — detected $(uname -s)"; exit 1; }

bold "==> Checking dependencies"
TRAC="/Library/Application Support/Checkpoint/Endpoint Connect/trac"
[[ -x "$TRAC" ]] || { err "Check Point Endpoint Security VPN not installed (looking for $TRAC)"; exit 1; }
ok "trac CLI present"

MISSING=""
for cmd in oathtool expect security osascript; do
  command -v "$cmd" >/dev/null || MISSING="$MISSING $cmd"
done
if [[ -n "$MISSING" ]]; then
  err "missing tools:$MISSING"
  err "install with: brew install oath-toolkit expect"
  exit 1
fi
ok "oath-toolkit, expect, security, osascript present"

if [[ -n "$QR_PATH" ]]; then
  command -v zbarimg >/dev/null || { err "zbarimg required for --qr (brew install zbar)"; exit 1; }
  ok "zbar present"
fi

# --- Site ---
bold "\n==> VPN gateway site"
print -n "Enter your VPN site hostname (e.g. vpn.example.com): "
read VPN_SITE
[[ -n "$VPN_SITE" ]] || { err "site cannot be empty"; exit 1; }

# --- Username ---
bold "\n==> VPN username"
print -n "Enter your LDAP/VPN username: "
read VPN_USER
[[ -n "$VPN_USER" ]] || { err "username cannot be empty"; exit 1; }

# --- Password ---
bold "\n==> VPN password"
read -s "VPN_PASS?Enter your LDAP password (input hidden): "
print
[[ -n "$VPN_PASS" ]] || { err "password cannot be empty"; exit 1; }

# --- TOTP secret ---
bold "\n==> TOTP secret"
TOTP_SECRET=""
if [[ -n "$QR_PATH" ]]; then
  [[ -f "$QR_PATH" ]] || { err "QR file not found: $QR_PATH"; exit 1; }
  print "  Decoding QR..."
  URL=$(zbarimg --raw -q "$QR_PATH" 2>/dev/null | head -1)
  [[ "$URL" == otpauth-migration://* ]] || { err "QR doesn't contain a Google Authenticator migration payload"; exit 1; }
  TOTP_SECRET=$(/usr/bin/env python3 - "$URL" <<'PY'
import sys, base64, urllib.parse
url = sys.argv[1]
data = base64.b64decode(urllib.parse.parse_qs(urllib.parse.urlparse(url).query)['data'][0])
# Walk the protobuf to find the first OtpParameters' secret (field 1, bytes).
# Outer message: field 1 (otp_parameters) is length-delimited.
i = 0
assert data[i] == 0x0a, "unexpected protobuf layout (outer tag)"
i += 1
# Outer length is a varint
def varint(b, j):
    r, s = 0, 0
    while True:
        x = b[j]; j += 1
        r |= (x & 0x7f) << s
        if not (x & 0x80): return r, j
        s += 7
_, i = varint(data, i)
# Inside OtpParameters: field 1 is the secret (bytes)
assert data[i] == 0x0a, "unexpected protobuf layout (inner tag)"
i += 1
slen, i = varint(data, i)
secret = data[i:i+slen]
print(base64.b32encode(secret).decode().rstrip('='))
PY
)
  [[ -n "$TOTP_SECRET" ]] || { err "failed to extract secret from QR"; exit 1; }
  ok "extracted secret from QR (${#TOTP_SECRET} chars)"
else
  print "  How to get this: see README section 'Extracting the TOTP secret'."
  print "  Or re-run with --qr <path-to-screenshot>."
  read -s "TOTP_SECRET?Paste base32 TOTP secret (input hidden): "
  print
fi
[[ -n "$TOTP_SECRET" ]] || { err "TOTP secret cannot be empty"; exit 1; }

# Verify TOTP — generate a code so user can compare with their phone
TEST_CODE=$(oathtool --totp -b "$TOTP_SECRET" 2>/dev/null) || { err "oathtool rejected the secret — not valid base32?"; exit 1; }
ok "TOTP secret accepted; current code: $TEST_CODE"
print -n "  Does this match your authenticator app right now? [y/N]: "
read CONFIRM
[[ "$CONFIRM" =~ ^[Yy] ]] || { err "aborted by user"; exit 1; }

# --- Stash in Keychain ---
bold "\n==> Stashing in Keychain"
security add-generic-password -s checkpoint-vpn-site -a default -w "$VPN_SITE"   -U && ok "site stored"
security add-generic-password -s checkpoint-vpn-user -a default -w "$VPN_USER"   -U && ok "username stored"
security add-generic-password -s checkpoint-vpn-pass -a default -w "$VPN_PASS"   -U && ok "password stored"
security add-generic-password -s checkpoint-vpn-totp -a default -w "$TOTP_SECRET" -U && ok "TOTP secret stored"
unset VPN_PASS TOTP_SECRET TEST_CODE

# --- Install scripts ---
bold "\n==> Installing scripts to ~/bin"
mkdir -p "$HOME/bin"
for f in vpn-connect vpn-pause vpn-resume; do
  cp "$SCRIPT_DIR/bin/$f" "$HOME/bin/$f"
  chmod +x "$HOME/bin/$f"
  ok "$HOME/bin/$f"
done

# --- PATH ---
if ! grep -q 'HOME/bin' "$HOME/.zshrc" 2>/dev/null; then
  print "" >> "$HOME/.zshrc"
  print '# Added by checkpoint-vpn-autologin-macos install.sh' >> "$HOME/.zshrc"
  print 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
  ok "added ~/bin to PATH in ~/.zshrc (open a new terminal to pick it up)"
else
  ok "~/bin already in PATH"
fi

# --- LaunchAgent ---
bold "\n==> Installing LaunchAgent (auto-reconnect every 2 min)"
PLIST_DEST="$HOME/Library/LaunchAgents/com.${USER}.vpn-keepalive.plist"
mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__USER__|${USER}|g" -e "s|__HOME__|${HOME}|g" \
  "$SCRIPT_DIR/launchd/com.user.vpn-keepalive.plist" > "$PLIST_DEST"
launchctl unload "$PLIST_DEST" 2>/dev/null || true
launchctl load "$PLIST_DEST"
ok "loaded $PLIST_DEST"

# --- Test ---
bold "\n==> Smoke test"
"$HOME/bin/vpn-connect" >/dev/null 2>&1 && RC=$? || RC=$?
case $RC in
  0) ok "vpn-connect ran (exit 0 — likely already connected, or new connect succeeded)" ;;
  *) warn "vpn-connect exited $RC — check ~/.vpn-connect.log for details. May need to be on a network where the VPN gateway is reachable." ;;
esac

bold "\n==> Done"
cat <<DONE

Daily usage:
  vpn-connect    # connect (or use a hotkey, see README)
  vpn-pause      # disable auto-reconnect (e.g., at home)
  vpn-resume     # re-enable
  tail -f ~/.vpn-connect.log

Keychain entries created (account=default):
  checkpoint-vpn-{site,user,pass,totp}

LaunchAgent: $PLIST_DEST

REMINDER: if you used --qr, delete the QR screenshot now from your Mac and your phone.
DONE
