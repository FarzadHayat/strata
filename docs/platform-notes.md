# Platform notes (empirical, macOS 27.0 / MacBook Pro Mac17,2 / Karabiner-DriverKit-VirtualHIDDevice 8.5.0)

Results of the `strata probe` spike, 2026-09-16. These drive design decisions in the engine and daemon.

## Virtual keyboard (Karabiner-VirtualHIDDevice-Daemon, client protocol 7)
- Socket `/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock`, SOCK_STREAM,
  frames `u32 BE size | u8 type | u64 BE request_id | payload`, payload `u16 LE protocol=7 | u8 request | struct`.
- Handshake timeline observed: connect → `driver_activated` (+100 ms) → `driver_connected` (+5 ms) →
  `virtual_hid_keyboard_ready` (+1.0 s after `virtual_hid_keyboard_initialize`). Gate all reports on ready.
- **Each client gets its own virtual keyboard device** (a second "Karabiner DriverKit VirtualHIDKeyboard 1.8.0"
  appeared for the probe while kmonad's was still present). Filter *all* pqrs.org virtual keyboards from seizing.
- Verified outputs (observed on the virtual device and by effect): keyboard page `a` (0x07/0x04); consumer
  `volume_increment` 0x0C/0xE9 (system volume 28 → 31); top-case `brightness_up` 0xFF/0x04 (Farzad's working kmonad
  mapping — `brdn` = 0xFF/0x05). The HID array field also toggles a phantom `usage 0xFFFF` element; ignore it on input.
- The daemon's LaunchDaemon plist shipped with `com.apple.quarantine` set → `launchctl bootstrap` fails with
  "Input/output error" (error 155 "Refusing to execute/trust quarantined program/file" in launchd's log).
  Fix: `xattr -d com.apple.quarantine /Library/LaunchDaemons/org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist`
  (and `-dr` on the daemon .app). `install.sh` must do this. This is why the old `sudo -n karabiner-vhidd` strays existed.

## Physical internal keyboard ("Apple Internal Keyboard / Trackpad", transport FIFO, usage 1:6)
- Seizing with `kIOHIDOptionsTypeSeizeDevice` works from a root process. A second seize attempt fails with
  `kIOReturnExclusiveAccess` (0xE00002C5) — used to detect kmonad/Karabiner conflicts.
- Elements on the seized 1:6 node: 271 keyboard-page buttons, consumer buttons (0xB3 0xB4 0xB5 0xB6 0xB8 0xCD),
  LED outputs 0x08/0x01–0x05, **Apple top-case `0xFF/0x03` (fn) as an input element**, `0xFF00/0x06` in-misc,
  `0xFF01/0x0B` feature. ⇒ **Fn/Globe IS delivered on the seized keyboard node** (branch A of the plan): the engine
  owns the fn-row flip and passes `fn` through to the virtual keyboard.
- Brightness/illumination keys did not appear as elements of the 1:6 node; they live on the separate 0xFF00/11
  top-case node which we do not seize (they keep working natively).
- TCC: a root process started from a terminal with grants reported `IOHIDCheckAccess = granted` and
  `AXIsProcessTrusted = true` and seized successfully (attribution to the responsible terminal process). A
  LaunchDaemon has no responsible process, so the bundle + GUI-prompt flow from the plan is still required.

## Caps lock
- `IOHIDSetModifierLockState(kIOHIDParamConnectType, kIOHIDCapsLockState)` works from root: false → true → false,
  read back with `IOHIDGetModifierLockState`. Engine routes caps-lock *output* through this toggle (on press).

## Open (needs a human at the keyboard)
- Whether macOS applies its own fn semantics to F-keys sent by the virtual keyboard while our virtual `fn` is held.
  Karabiner-Elements' design implies it does not; Strata therefore emits the resolved key itself (media or F-key).

## Code signing / TCC identity
- Self-signed identity "Strata Signing" (created by `scripts/make-signing-cert.sh`, RSA-2048, codeSigning EKU, trusted
  for code signing in the login keychain). `codesign --identifier dev.farzadhayat.strata -s "Strata Signing"` yields the
  designated requirement `identifier "dev.farzadhayat.strata" and certificate root = H"<sha1>"`, i.e. stable across
  rebuilds — unlike ad-hoc (`cdhash H"…"`), which changes every build and makes TCC forget the app.
- `codesign --verify --strict` passes; Gatekeeper is not involved because `curl` downloads carry no quarantine flag.

## Tooling
- `swift test` needs XCTest, which the Command Line Tools SDK lacks. With Xcode installed, `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test` works (license accepted via `xcodebuild -license accept`). The Makefile sets this automatically.
