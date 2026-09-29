# Changelog

## Unreleased
- Keyboards panel (Layout settings): turn Strata on or off per keyboard. Off writes the product name to
  `exclude-devices` and takes effect immediately — no daemon restart; the keyboard works normally again.
- `exclude-devices` entries now match a keyboard's whole product name (case-insensitive), not a substring, so
  disabling “Keychron K2” no longer also disables “Keychron K2 Pro”. Update partial names in existing configs.

## 0.2.2 — 2026-09-17
- Daemon: accept config paths under `~/.config/strata` when `keymap.kbd` is a symlink (GNU stow / dotfiles).

## 0.2.1 — 2026-09-17
- Visualizer: corner picker snaps correctly again (clears stale dragged position; do not persist corner-snapped frames).
- Visualizer: **Size** slider in menu bar options (260–720 pt); edge drag still works when click-through is off.

## 0.2.0 — 2026-09-16
- On-screen keyboard visualizer: floating always-on-top panel (corner, opacity, click-through settings) that shows the
  active layer, effective per-key bindings and live key presses. Key events are streamed over IPC only while it is shown
  (`strata status --watch --keys` shows the same stream).
- `--editor` / `--visualizer` launch flags; `open -a Strata` opens the editor.

## 0.1.0 — 2026-09-16
Initial release.
- Root daemon: IOKit keyboard seizing, Karabiner-DriverKit-VirtualHIDDevice client (protocol 7), layer engine with
  tap-hold (permissive / hold-on-press / timeout), chords, layer-while-held / layer-switch, hardware-default function row,
  caps-lock via IOHIDSystem, FSEvents config reload, panic chord (⌃⌥⌘Esc).
- `.kbd` config format (kmonad/kanata flavoured) with lossless GUI editing and precise diagnostics.
- SwiftUI menu-bar app with permission checklist and a visual keyboard editor.
- `install.sh` one-liner, `uninstall.sh`, signed `Strata.app` built with SwiftPM only.
