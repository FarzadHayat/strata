#!/bin/bash
# Removes Strata (app, launchd jobs, logs). Keeps your config unless --purge. Keeps the Karabiner driver unless --remove-driver.
set -euo pipefail
PURGE=0; REMOVE_DRIVER=0
for a in "$@"; do case "$a" in --purge) PURGE=1 ;; --remove-driver) REMOVE_DRIVER=1 ;; *) echo "unknown option $a"; exit 2 ;; esac; done
USER_NAME="${SUDO_USER:-$USER}"; USER_UID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')"
DAEMON_LABEL="dev.farzadhayat.strata.daemon"; AGENT_LABEL="dev.farzadhayat.strata.agent"
echo "==> stopping Strata"
launchctl bootout "gui/$USER_UID/$AGENT_LABEL" 2>/dev/null || true
sudo launchctl bootout "system/$DAEMON_LABEL" 2>/dev/null || true
pkill -x Strata 2>/dev/null || true
echo "==> removing files"
sudo rm -f "/Library/LaunchDaemons/$DAEMON_LABEL.plist"
rm -f "$USER_HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
sudo rm -rf /Applications/Strata.app /var/log/strata /var/run/strata
sudo rm -f /etc/sudoers.d/strata 2>/dev/null || true
if [ "$PURGE" = 1 ]; then rm -rf "$USER_HOME/.config/strata"; echo "removed $USER_HOME/.config/strata"; else echo "kept $USER_HOME/.config/strata"; fi
if [ "$REMOVE_DRIVER" = 1 ]; then
  echo "==> removing Karabiner-DriverKit-VirtualHIDDevice"
  bash '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh' 2>/dev/null || true
  sudo bash '/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh' 2>/dev/null || true
  sudo pkill -x Karabiner-VirtualHIDDevice-Daemon 2>/dev/null || true
fi
echo "Strata uninstalled. You may also remove it from System Settings › Privacy & Security › Input Monitoring / Accessibility."
