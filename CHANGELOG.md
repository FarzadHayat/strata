# Changelog

## 0.1.0 — 2026-09-16
Initial release.
- Root daemon: IOKit keyboard seizing, Karabiner-DriverKit-VirtualHIDDevice client (protocol 7), layer engine with
  tap-hold (permissive / hold-on-press / timeout), chords, layer-while-held / layer-switch, hardware-default function row,
  caps-lock via IOHIDSystem, FSEvents config reload, panic chord (⌃⌥⌘Esc).
- `.kbd` config format (kmonad/kanata flavoured) with lossless GUI editing and precise diagnostics.
- SwiftUI menu-bar app with permission checklist and a visual keyboard editor.
- `install.sh` one-liner, `uninstall.sh`, signed `Strata.app` built with SwiftPM only.
