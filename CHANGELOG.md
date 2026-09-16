# Changelog

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
