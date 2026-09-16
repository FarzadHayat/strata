#!/bin/bash
# Strata installer — programmable keyboard layers for macOS (Apple Silicon).
#   curl -fsSL https://raw.githubusercontent.com/FarzadHayat/strata/main/install.sh | bash
# Options (append after `bash -s --`):
#   --from-source        build from the current checkout instead of downloading a release
#   --app PATH           install an already-built Strata.app (used by `make dev`)
#   --version vX.Y.Z     install a specific release
#   --replace-kmonad     stop/unload kmonad without asking
#   --dry-run            print what would happen
# Re-running is safe (idempotent). Needs sudo for /Applications, the LaunchDaemon and the Karabiner driver.
set -euo pipefail

REPO_SLUG="FarzadHayat/strata"
APP_DST="/Applications/Strata.app"
DAEMON_LABEL="dev.farzadhayat.strata.daemon"
AGENT_LABEL="dev.farzadhayat.strata.agent"
VHID_VERSION="8.5.0"
VHID_PKG_URL="https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice/releases/download/v${VHID_VERSION}/Karabiner-DriverKit-VirtualHIDDevice-${VHID_VERSION}.pkg"
VHID_TEAM_ID="G43BCU2T37"
VHID_PLIST="/Library/LaunchDaemons/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist"
VHID_LABEL="org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon"
VHID_MANAGER="/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager"

FROM_SOURCE=0; APP_SRC=""; VERSION=""; REPLACE_KMONAD=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from-source) FROM_SOURCE=1 ;;
    --app) APP_SRC="$2"; shift ;;
    --version) VERSION="$2"; shift ;;
    --replace-kmonad) REPLACE_KMONAD=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac; shift
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then echo "+ $*"; else "$@"; fi; }
as_root() { if [ "$DRY" = 1 ]; then echo "+ sudo $*"; elif [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
# user-level steps (files in $HOME, gui launchd domain) — drop privileges if the installer itself runs as root
as_user() { if [ "$DRY" = 1 ]; then echo "+ (as $USER_NAME) $*"; elif [ "$(id -u)" = 0 ]; then sudo -u "$USER_NAME" "$@"; else "$@"; fi; }

USER_NAME="${SUDO_USER:-$USER}"
USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "$USER_HOME" ] || USER_HOME="$HOME"
CONFIG_DIR="$USER_HOME/.config/strata"
CONFIG="$CONFIG_DIR/keymap.kbd"

bold "Strata installer"
[ "$(uname -m)" = "arm64" ] || die "Strata supports Apple Silicon Macs only (found $(uname -m))."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || die "macOS 14 or newer required (found $(sw_vers -productVersion))."
echo "user: $USER_NAME (uid $USER_UID)   config: $CONFIG"
echo "You will be asked for your password (sudo) to install into /Applications and /Library/LaunchDaemons."
if [ "$DRY" = 0 ] && [ "$(id -u)" != 0 ]; then sudo -v || die "sudo is required"; fi

# ---------------------------------------------------------------- 1. get Strata.app
step "Getting Strata.app"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
if [ -n "$APP_SRC" ]; then
  [ -d "$APP_SRC" ] || die "no app at $APP_SRC"
elif [ "$FROM_SOURCE" = 1 ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$HERE/Package.swift" ] || die "--from-source must run from a strata checkout"
  command -v swift >/dev/null || die "swift toolchain not found (install Xcode Command Line Tools)"
  run "$HERE/scripts/build-app.sh" --out "$WORK/dist"
  APP_SRC="$WORK/dist/Strata.app"
else
  command -v curl >/dev/null || die "curl not found"
  if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$VERSION" ] || die "could not determine the latest release (offline? no releases yet?). Use --from-source."
  fi
  ZIP_URL="https://github.com/$REPO_SLUG/releases/download/$VERSION/Strata-${VERSION#v}.zip"
  echo "downloading $ZIP_URL"
  run curl -fsSL "$ZIP_URL" -o "$WORK/Strata.zip"
  run ditto -x -k "$WORK/Strata.zip" "$WORK/unzipped"
  APP_SRC="$WORK/unzipped/Strata.app"
  [ "$DRY" = 1 ] || [ -d "$APP_SRC" ] || die "download did not contain Strata.app"
fi
[ "$DRY" = 1 ] || xattr -dr com.apple.quarantine "$APP_SRC" 2>/dev/null || true

# ---------------------------------------------------------------- 2. Karabiner virtual HID driver
step "Checking Karabiner-DriverKit-VirtualHIDDevice (virtual keyboard driver)"
driver_active() { systemextensionsctl list 2>/dev/null | grep -q "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.*activated enabled"; }
if [ -x "$VHID_MANAGER" ]; then
  INSTALLED_VHID="$(defaults read /Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null || echo 0)"
  echo "installed package version: $INSTALLED_VHID"
  case "$INSTALLED_VHID" in
    8.*) ;;
    *) warn "Strata needs Karabiner-DriverKit-VirtualHIDDevice 8.x (client protocol 7); found $INSTALLED_VHID. Upgrading." ; INSTALL_VHID=1 ;;
  esac
else
  INSTALL_VHID=1
fi
if [ "${INSTALL_VHID:-0}" = 1 ]; then
  if [ -d "/Applications/Karabiner-Elements.app" ]; then
    warn "Karabiner-Elements is installed; it manages this driver itself. Update Karabiner-Elements to a version shipping driver 8.x instead of letting Strata install it."
  else
    echo "downloading $VHID_PKG_URL"
    run curl -fsSL "$VHID_PKG_URL" -o "$WORK/vhid.pkg"
    if [ "$DRY" = 0 ]; then
      pkgutil --check-signature "$WORK/vhid.pkg" | grep -q "$VHID_TEAM_ID" || die "driver package signature check failed (expected Team ID $VHID_TEAM_ID)"
    fi
    as_root installer -pkg "$WORK/vhid.pkg" -target /
  fi
fi
if [ -x "$VHID_MANAGER" ] && ! driver_active; then
  echo "activating the driver extension…"
  as_root "$VHID_MANAGER" forceActivate || true
  bold "ACTION NEEDED: approve 'Karabiner-DriverKit-VirtualHIDDevice' in System Settings › General › Login Items & Extensions › Driver Extensions (a restart may be required on first install)."
fi
# The pkg's LaunchDaemon plist sometimes carries a quarantine attribute, which makes launchd refuse it.
if [ -f "$VHID_PLIST" ]; then
  as_root xattr -d com.apple.quarantine "$VHID_PLIST" 2>/dev/null || true
  as_root xattr -dr com.apple.quarantine "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications" 2>/dev/null || true
  # launchd must own exactly one copy of the daemon. Kill ad-hoc copies (e.g. started with `sudo -n`) only when
  # launchd is not already running it, so re-running the installer does not interrupt a working setup.
  if [ "$DRY" = 1 ] || ! as_root launchctl print "system/$VHID_LABEL" 2>/dev/null | grep -q "state = running"; then
    as_root pkill -f "Karabiner-VirtualHIDDevice-Daemon|karabiner-vhidd" 2>/dev/null || true
    as_root launchctl enable "system/$VHID_LABEL" 2>/dev/null || true
    as_root launchctl bootstrap system "$VHID_PLIST" 2>/dev/null || as_root launchctl kickstart -k "system/$VHID_LABEL" 2>/dev/null || true
  else
    echo "virtual keyboard daemon already running under launchd"
  fi
fi

# ---------------------------------------------------------------- 3. kmonad / Karabiner conflicts
step "Checking for other keyboard remappers"
if pgrep -x kmonad >/dev/null || [ -f "$USER_HOME/Library/LaunchAgents/org.kmonad.kmonad.plist" ] || [ -d /Applications/KmonadHelper.app ]; then
  if [ "$REPLACE_KMONAD" = 0 ] && [ "$DRY" = 0 ] && [ -t 0 ]; then
    read -r -p "kmonad is installed/running and will conflict with Strata. Stop and unload it now? [Y/n] " ans
    case "$ans" in n|N) ;; *) REPLACE_KMONAD=1 ;; esac
  elif [ "$REPLACE_KMONAD" = 0 ]; then
    REPLACE_KMONAD=1   # non-interactive (curl | bash): a running remapper would make Strata unusable
  fi
  if [ "$REPLACE_KMONAD" = 1 ]; then
    as_user launchctl bootout "gui/$USER_UID/org.kmonad.kmonad" 2>/dev/null || true
    as_root pkill -x kmonad 2>/dev/null || true
    [ -f "$USER_HOME/Library/LaunchAgents/org.kmonad.kmonad.plist" ] && as_user mv "$USER_HOME/Library/LaunchAgents/org.kmonad.kmonad.plist" "$USER_HOME/Library/LaunchAgents/org.kmonad.kmonad.plist.disabled"
    echo "kmonad stopped (its files were left in place; its LaunchAgent plist was renamed to *.disabled)."
  fi
fi
if pgrep -x karabiner_grabber >/dev/null || pgrep -x Karabiner-Core-Service >/dev/null; then
  warn "Karabiner-Elements is running. Quit it (or disable its device grabbing) — two programs cannot seize the same keyboard."
fi

# ---------------------------------------------------------------- 4. install app + launchd jobs
step "Installing $APP_DST"
if [ -f "$APP_DST/Contents/MacOS/Strata" ]; then
  as_root launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
  as_user launchctl bootout "gui/$USER_UID/$AGENT_LABEL" 2>/dev/null || true
  as_user pkill -f "Strata.app/Contents/MacOS/Strata\$" 2>/dev/null || true   # stale GUI instances
  as_root rm -rf "$APP_DST"
fi
as_root ditto "$APP_SRC" "$APP_DST"
as_root chown -R root:wheel "$APP_DST"
as_root chmod -R go-w "$APP_DST"
as_root mkdir -p /var/log/strata /var/run/strata

step "Seeding config at $CONFIG"
as_user mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG" ]; then
  SEED="$APP_DST/Contents/Resources/configs/qwerty-extend.kbd"
  if [ -f "$USER_HOME/.config/kmonad/colemak.kbd" ] && [ -f "$APP_DST/Contents/Resources/configs/colemak-dh-extend.kbd" ]; then
    SEED="$APP_DST/Contents/Resources/configs/colemak-dh-extend.kbd"
  fi
  as_user cp "$SEED" "$CONFIG"
  echo "created $CONFIG from $(basename "$SEED")"
else
  echo "keeping existing config"
fi
[ "$DRY" = 1 ] || "$APP_DST/Contents/MacOS/Strata" compile "$CONFIG" || warn "your config has errors; the daemon will keep waiting until it compiles"

step "Installing launchd jobs"
DAEMON_PLIST="/Library/LaunchDaemons/$DAEMON_LABEL.plist"
AGENT_PLIST="$USER_HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
RES="$APP_DST/Contents/Resources"; [ -f "$RES/$DAEMON_LABEL.plist" ] || RES="$APP_SRC/Contents/Resources"
if [ -f "$RES/$DAEMON_LABEL.plist" ]; then
  sed -e "s|__USER__|$USER_NAME|" -e "s|__CONFIG__|$CONFIG|" "$RES/$DAEMON_LABEL.plist" > "$WORK/daemon.plist"
else
  [ "$DRY" = 1 ] || die "launchd plists missing from the app bundle"
  echo "+ (dry run) render $DAEMON_LABEL.plist"; : > "$WORK/daemon.plist"
fi
as_root cp "$WORK/daemon.plist" "$DAEMON_PLIST"
as_root chown root:wheel "$DAEMON_PLIST"; as_root chmod 644 "$DAEMON_PLIST"
as_user mkdir -p "$USER_HOME/Library/LaunchAgents"
as_user cp "$RES/$AGENT_LABEL.plist" "$AGENT_PLIST"
as_root launchctl bootstrap system "$DAEMON_PLIST" 2>/dev/null || as_root launchctl kickstart -k "system/$DAEMON_LABEL"
as_user launchctl bootstrap "gui/$USER_UID" "$AGENT_PLIST" 2>/dev/null || as_user launchctl kickstart -k "gui/$USER_UID/$AGENT_LABEL"

step "Done"
cat <<MSG
Strata is installed and will start at login.
  • The menu bar icon (⌨︎) shows status and opens the layout editor.
  • Config file: $CONFIG  (edit by hand or in the editor — changes apply instantly)
  • Logs: /var/log/strata/daemon.log

If macOS asks for permissions, allow Strata under System Settings › Privacy & Security ›
  "Input Monitoring" and "Accessibility" (called "Device Control and Data Access" on macOS 27).
The menu bar panel shows what is still missing.
MSG
