# Strata

**Programmable keyboard layers for macOS on Apple Silicon.** A native Swift menu-bar app plus a tiny root daemon
that seizes your keyboard at the HID level and re-emits it through a virtual keyboard, so *every* key can be
remapped — Caps Lock, Fn/Globe, media keys, everything — and it keeps working in password fields and Secure
Keyboard Entry.

- **Fully remappable base layer** (e.g. Colemak-DH on a QWERTY MacBook).
- **Layers activated by holding a key** — hold Caps Lock for an "Extend" layer with arrows, Home/End, Page Up/Down,
  copy/paste, media keys, or any shortcut under your fingers; tap it for Escape.
- **Every hardware key keeps its default** unless you remap it: untouched F-keys still do brightness/volume/media,
  fn+F1 is still F1, the Globe key still opens emoji.
- **One human-readable config file** (`~/.config/strata/keymap.kbd`) you can edit by hand *or* in the visual
  editor — GUI edits are lossless (your comments and alignment survive). Changes apply within ~100 ms.
- **Single-command install**, permission prompts on first launch, starts at login, no Xcode needed to build.

<!-- screenshot: docs/editor.png -->

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/FarzadHayat/strata/main/install.sh | bash
```

The installer (idempotent, asks for your password once) will:

1. download the latest `Strata.app` release into `/Applications` (root-owned, since the daemon runs as root);
2. install and activate [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
   8.x (the virtual keyboard driver, public domain, signed by pqrs.org) if it is not already there, and make sure
   exactly one copy of its daemon runs under launchd;
3. stop kmonad if it is running (it would fight over the keyboard; its files are left in place);
4. create `~/.config/strata/keymap.kbd` (QWERTY + Extend starter, or the Colemak-DH layout if it finds a kmonad
   config), install the LaunchDaemon (root remapper) and LaunchAgent (menu-bar app) and start both.

Then approve what macOS asks for — the menu-bar panel shows exactly what is still missing:

| Prompt | Where | Why |
|---|---|---|
| Driver extension | System Settings › General › Login Items & Extensions › **Driver Extensions** → allow *Karabiner-DriverKit-VirtualHIDDevice* (first install only; may need a restart) | the virtual keyboard |
| Input Monitoring | Privacy & Security › **Input Monitoring** → Strata | reading the keyboard |
| Accessibility | Privacy & Security › **Accessibility** (on macOS 27: **Device Control and Data Access**) → Strata | exclusive access to the keyboard |

The daemon notices new grants within two seconds and seizes the keyboard — no restart needed. Requirements:
macOS 14+, Apple Silicon.

Uninstall: `/Applications/Strata.app/Contents/Resources/uninstall.sh` (add `--purge` to delete the config,
`--remove-driver` to remove the Karabiner driver too).

## The config file

`~/.config/strata/keymap.kbd` uses a small S-expression dialect that kmonad/kanata users will recognise.
A complete example is [`configs/colemak-dh-extend.kbd`](configs/colemak-dh-extend.kbd); the starter is
[`configs/qwerty-extend.kbd`](configs/qwerty-extend.kbd).

```lisp
(defcfg
  tap-hold-resolution permissive   ;; permissive | hold-on-press | timeout
  tap-timeout   200                ;; ms — re-press within this after a tap repeats the tap action
  hold-timeout  200                ;; ms — held longer than this counts as a hold
  prior-idle    120                ;; ms — pressed right after another key ⇒ always a tap (fast-typing guard)
  fn-row        system)            ;; system | media | function

(defsrc                            ;; the physical keys, in the order the layers use
  esc  f1   f2   f3   f4   f5   f6   f7   f8   f9   f10  f11  f12
  grv  1    2    3    4    5    6    7    8    9    0    -    =    bspc
  tab  q    w    e    r    t    y    u    i    o    p    [    ]    \
  caps a    s    d    f    g    h    j    k    l    ;    '    ret
  lsft z    x    c    v    b    n    m    ,    .    /    rsft up
  fn   lctl lalt lmet           spc            rmet ralt left down right)

(defalias
  ext (tap-hold esc (layer-while-held extend))   ;; tap → esc, hold → extend layer
  cpy M-c  pst M-v)

(deflayer base                     ;; first layer = base; "_" = keep the key's normal behaviour
  _    _    _    _    _    _    _    _    _    _    _    _    _
  _    _    _    _    _    _    _    _    _    _    _    _    _    _
  _    _    _    _    _    _    _    _    _    _    _    _    _    _
  @ext _    _    _    _    _    _    _    _    _    _    _    _
  _    _    _    _    _    _    _    _    _    _    _    _    _
  _    _    _    _              _              _    _    _    _    _)

(deflayer extend
  _    _    _    _    _    _    _    _    _    _    _    _    _
  _    f1   f2   f3   f4   f5   f6   f7   f8   f9   f10  f11  f12  _
  _    _    _    _    _    _    _    pgup up   pgdn _    _    _    _
  _    lalt lmet lsft lalt _    home left down right end  _    _
  _    M-z  @cut @cpy @pst _    bspc del  _    _    _    _    _
  _    _    _    _              ret            _    _    _    _    _)
```

### Actions

| Syntax | Meaning |
|---|---|
| `a`, `f5`, `volu`, `brdn`, `mctl`, `spot`, `dict`, `dnd`, `pp`, `next`, … | send that key (see the key names below) |
| `_` | transparent: fall through to the layer below, ultimately the key's hardware default |
| `XX` | block the key |
| `@name` | an alias from `(defalias …)` |
| `M-c`, `C-S-tab`, `A-left`, `RM-x` | chord: `M-` ⌘, `C-` ⌃, `A-` ⌥, `S-` ⇧ (prefix `R` for the right-hand modifier); `(chord lmet lsft c)` is the long form |
| `!`, `*`, `+`, `{`, `:`, `?` … | shifted symbol (= `S-` + the base key) |
| `(layer-while-held L)` (alias `layer-toggle`) | activate layer `L` while held |
| `(layer-switch L)` | make `L` the base layer |
| `(tap-hold TAP HOLD)` · `(tap-hold 200 150 TAP HOLD)` | tap action / hold action, optionally `tap-timeout hold-timeout` ms; `tap-hold-press`, `tap-hold-release` (= kmonad `tap-hold-next-release`), `tap-hold-timeout` pick the decision rule per key |

**Tap-hold rules.** `permissive` (default, best for a Caps-Lock layer while typing fast): it becomes a hold when the
timeout passes *or* when another key is pressed **and released** while it is down. `hold-on-press`: any other key
press makes it a hold. `timeout`: only the timer decides. `prior-idle` forces a tap if you pressed another key
within the last N ms (rolling into the key never triggers the layer). Re-pressing within `tap-timeout` after a tap
repeats the tap (so `esc esc` works and holding it auto-repeats).

**Function row.** With `fn-row system` (default) unmapped F-keys follow the macOS setting *Use F1, F2, etc. keys
as standard function keys*, exactly like a stock MacBook: F1/F2 brightness, F3 Mission Control, F4 Spotlight,
F5 Dictation, F6 Focus, F7–F9 media, F10–F12 volume; holding `fn` flips them. `media` / `function` force one
behaviour.

### Key names

Canonical names are the short kanata/kmonad ones; Karabiner-Elements long names (`left_command`,
`volume_increment`, …) and common aliases are accepted, matching is case-insensitive.

- Letters `a`–`z`, digits `0`–`9`, symbols `` ` - = [ ] \ ; ' , . / `` (or `grv min eql lbrc rbrc bksl scln apo comm dot slash`), `102d` (ISO §), `nuhs`
- `esc tab spc ret bspc del ins caps prnt slck pause menu power`
- Modifiers `lsft rsft lctl rctl lalt ralt lmet rmet fn` (`cmd`, `opt`, `ctrl`, `shift`, `globe` also work)
- Navigation `left right up down home end pgup pgdn`
- `f1`–`f24`, keypad `kp0`–`kp9 kp/ kp* kp- kp+ kp. kp= kprt nlck`
- Media `volu vold mute pp play stop next prev ffwd rewind eject brup brdn blup bldn bltog`
- System `mctl spot lp desktop dict dnd sleep www mail calc back forward refresh`

Run `strata compile ~/.config/strata/keymap.kbd` to validate a file; errors come with `line:column` and a
"did you mean" hint.

## The editor

Click the ⌨︎ menu-bar icon → **Open Editor**. Pick a layer, click a key on the drawn MacBook keyboard (or press
the physical key with *Select by pressing*), and choose what it should do in the inspector: a key, a chord, a
layer, a tap-hold, an alias, transparent or blocked. Every change is written straight into your `.kbd` file as
a minimal edit and the daemon reloads it instantly; the status bar tells you if the daemon rejected it. The menu
bar shows the active layer name live while you hold a layer key.

## How it works (and why)

```
physical keyboard ──seized (IOKit, root)──▶ Strata daemon ──engine (layers, tap-hold)──▶ Karabiner virtual keyboard ──▶ macOS
```

- **Interception**: the daemon opens every keyboard with `IOHIDDeviceOpen(kIOHIDOptionsTypeSeizeDevice)`, so macOS never
  sees the raw events, and emits HID reports through the Karabiner-DriverKit-VirtualHIDDevice daemon (a Unix-socket
  protocol, client protocol 7). This is the same architecture as Karabiner-Elements and kanata and the most robust one
  available on current macOS: it works in Secure Input (password fields), it can remap Caps Lock and Fn properly, and
  there is no CGEventTap that can be disabled by a timeout or bypassed by other taps. Creating our own DriverKit or
  CoreHID virtual device would require Apple-approved entitlements; the pqrs driver is public domain and already
  signed and notarized.
- **Caps Lock** is toggled through `IOHIDSetModifierLockState` so the real LED and the system state stay in sync.
- **Permissions**: the GUI and the daemon are the *same signed executable* inside `Strata.app`, so the permissions you
  grant when the GUI prompts apply to the root daemon too. The app is signed with a persistent self-signed identity
  ("Strata Signing") rather than an ad-hoc signature so grants survive updates.
- **Safety**: the daemon never runs shell commands and only reads a config file under `~/.config/strata`. If it dies, the
  kernel releases the keyboard and everything returns to normal. Panic chord: **⌃⌥⌘ + Esc** (all four at once) pauses
  remapping (keys pass through unchanged); press it again to resume.
- **Reload**: the config directory is watched with FSEvents (safe with editors that save via rename), debounced, and
  a content hash prevents redundant reloads. Keys held during a reload keep their old mapping until released.

## Build from source

Requirements: macOS 14+ and **Xcode 16+** (the SwiftUI macros used by the editor and XCTest are only shipped
inside Xcode, not the Command Line Tools). Xcode does not need to be the selected developer directory: the
`Makefile` and `scripts/build-app.sh` export `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
automatically when Xcode is installed. No `.xcodeproj` — everything is SwiftPM.

```bash
git clone https://github.com/FarzadHayat/strata.git && cd strata
make build                 # .build/debug/strata
make test                  # unit tests (parser, compiler, editor, engine)
make app                   # dist/Strata.app + dist/Strata-<version>.zip (signed if the identity exists)
scripts/make-signing-cert.sh   # one-time: create the "Strata Signing" identity so TCC grants persist
make dev                   # build, install to /Applications, restart daemon + GUI
./install.sh --from-source # same, via the installer
```

Useful commands while hacking:

```bash
strata compile configs/colemak-dh-extend.kbd          # validate a config
sudo strata probe --elements --timeout 10             # see raw HID events / what the hardware exposes
sudo strata --daemon --dev-timeout 60                 # run the daemon in the foreground for a minute
strata check                                          # permission / driver status
sudo scripts/dev.sh status|logs|daemon-restart        # dev helper (see the script)
tail -f /var/log/strata/daemon.log
```

Layout: `Sources/StrataCore` (key tables, `.kbd` parser with lossless editing, compiler, engine — pure Swift,
unit-tested), `Sources/StrataHID` (IOKit seizing, virtual-HID client, caps lock, permissions),
`Sources/StrataIPC` (daemon ↔ GUI protocol), `Sources/Strata` (executable: `--daemon`, GUI, `probe`, `compile`,
`check`). `docs/platform-notes.md` records what was measured on real hardware.

## Troubleshooting

- **Nothing is remapped** → open the menu-bar panel: it lists what is missing (driver approval, permissions, daemon).
  `tail /var/log/strata/daemon.log` shows `not permitted` (grant permissions) or `exclusive access` (another remapper
  such as kmonad or Karabiner-Elements holds the keyboard — quit it).
- **Driver daemon won't start** (`connect(): No such file`) → `sudo launchctl print system/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon`.
  If launchd refuses the plist because of a quarantine attribute, re-run `install.sh` (it strips it).
- **Permissions reset after an update** → the build was ad-hoc signed; releases are signed with the persistent
  identity. Re-grant once.
- **Config error** → the menu bar turns red and shows `keymap.kbd:LINE:COL: …`; the previous good keymap stays active.
- **Emergency**: ⌃⌥⌘Esc pauses Strata; `sudo launchctl bootout system/dev.farzadhayat.strata.daemon` stops it.

## License

MIT. The Karabiner-DriverKit-VirtualHIDDevice driver is © pqrs.org, released into the public domain.
