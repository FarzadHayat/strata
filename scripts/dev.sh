#!/bin/bash
# Strata developer helper. Runs as root via a NOPASSWD sudoers rule during development:
#   farzad ALL=(root) NOPASSWD: /Users/farzad/Projects/strata/scripts/dev.sh
# Everything here is about the LOCAL dev loop; end users never run this.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEV_USER="${SUDO_USER:-${USER}}"
DEV_UID="$(id -u "$DEV_USER")"
PQRS_PLIST="/Library/LaunchDaemons/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist"
PQRS_LABEL="org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon"
KMONAD_LABEL="org.kmonad.kmonad"
STRATA_LABEL="dev.farzadhayat.strata.daemon"
LOGDIR="/var/log/strata"

need_root() { if [ "$(id -u)" -ne 0 ]; then echo "dev.sh must run as root (sudo scripts/dev.sh ...)" >&2; exit 1; fi; }
log() { printf '\033[1;34m==> %s\033[0m\n' "$*" >&2; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  vhid-fix)
    # One official Karabiner virtual HID daemon, managed by launchd; kill the sudo -n strays.
    need_root
    log "stopping stray Karabiner-VirtualHIDDevice-Daemon processes"
    pkill -f "karabiner-vhidd|Karabiner-VirtualHIDDevice-Daemon" 2>/dev/null || true
    sleep 1
    log "bootstrapping official daemon"
    launchctl bootstrap system "$PQRS_PLIST" 2>/dev/null || launchctl kickstart -k "system/$PQRS_LABEL"
    sleep 1
    launchctl print "system/$PQRS_LABEL" | grep -E "state|pid" | head -3
    pgrep -lf "karabiner-vhidd|Karabiner-VirtualHIDDevice-Daemon"
    ;;
  kmonad-stop)
    need_root
    log "stopping kmonad LaunchAgent + processes"
    launchctl bootout "gui/$DEV_UID/$KMONAD_LABEL" 2>/dev/null || true
    pkill -x kmonad 2>/dev/null || true
    sleep 0.5
    pgrep -lx kmonad || echo "kmonad stopped"
    ;;
  kmonad-start)
    need_root
    log "restoring kmonad"
    if pgrep -x kmonad >/dev/null; then echo "kmonad already running"; exit 0; fi
    PLIST="/Users/$DEV_USER/Library/LaunchAgents/$KMONAD_LABEL.plist"
    if [ -f "$PLIST" ] && launchctl bootstrap "gui/$DEV_UID" "$PLIST" 2>/dev/null; then
      sleep 2
    else
      # No usable LaunchAgent: run kmonad directly as root (same as Farzad's KmonadHelper did).
      nohup /Users/$DEV_USER/.local/bin/kmonad /Users/$DEV_USER/.config/kmonad/colemak.kbd >>/Users/$DEV_USER/Library/Logs/kmonad.log 2>&1 &
      disown || true
      sleep 2
    fi
    pgrep -lx kmonad || echo "WARNING: kmonad not running"
    ;;
  run)
    # Run a strata binary as root in the foreground with a deadman timeout, restoring kmonad afterwards.
    # usage: dev.sh run <path-to-strata-binary> [args...]
    need_root
    bin="$1"; shift
    mkdir -p "$LOGDIR"
    "$0" kmonad-stop >/dev/null 2>&1 || true
    trap '"$0" kmonad-start >/dev/null 2>&1 || true' EXIT
    log "running: $bin $*"
    "$bin" "$@"
    ;;
  daemon-restart)
    need_root
    launchctl kickstart -k "system/$STRATA_LABEL" && log "restarted $STRATA_LABEL"
    ;;
  daemon-stop)
    need_root
    launchctl bootout "system/$STRATA_LABEL" 2>/dev/null && log "stopped $STRATA_LABEL" || echo "not loaded"
    ;;
  daemon-start)
    need_root
    launchctl bootstrap system "/Library/LaunchDaemons/$STRATA_LABEL.plist" && log "started $STRATA_LABEL"
    ;;
  logs)
    tail -n "${1:-50}" "$LOGDIR"/*.log 2>/dev/null || true
    log "karabiner daemon log:"; tail -n 20 /var/log/karabiner/virtual_hid_device_service.log 2>/dev/null || true
    ;;
  status)
    need_root
    echo "--- launchd"; launchctl print "system/$PQRS_LABEL" 2>/dev/null | grep -E "state|pid" | head -2 || echo "pqrs daemon: not loaded"
    launchctl print "system/$STRATA_LABEL" 2>/dev/null | grep -E "state|pid" | head -2 || echo "strata daemon: not loaded"
    launchctl print "gui/$DEV_UID/$KMONAD_LABEL" 2>/dev/null | grep -E "state|pid" | head -2 || echo "kmonad agent: not loaded"
    echo "--- processes"; pgrep -lf "kmonad|karabiner-vhidd|Karabiner-VirtualHIDDevice-Daemon|strata" || true
    echo "--- rootonly"; ls -la "/Library/Application Support/org.pqrs/tmp/rootonly/" 2>/dev/null || true
    ;;
  sh)
    # Escape hatch for ad-hoc root commands during development: dev.sh sh 'command'
    need_root
    bash -c "$*"
    ;;
  help|*)
    cat >&2 <<USAGE
usage: sudo scripts/dev.sh <command>
  status          launchd/process overview
  vhid-fix        kill stray Karabiner daemons, bootstrap the official one
  kmonad-stop     bootout kmonad LaunchAgent (frees the keyboard for strata)
  kmonad-start    restore kmonad LaunchAgent
  run <bin> [..]  run a strata binary as root (stops kmonad first, restores it on exit)
  daemon-start|daemon-stop|daemon-restart   manage the strata LaunchDaemon
  logs [n]        tail strata + karabiner logs
  sh '<cmd>'      run an ad-hoc command as root
USAGE
    ;;
esac
