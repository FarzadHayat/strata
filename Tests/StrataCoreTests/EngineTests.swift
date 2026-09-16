import XCTest
@testable import StrataCore

final class EngineTests: XCTestCase {
    // MARK: - Keys

    private func K(_ name: String) -> HIDKey { KeyTable.key(named: name)! }

    private var caps: HIDKey { K("caps") }
    private var a: HIDKey { K("a") }
    private var d: HIDKey { K("d") }
    private var f: HIDKey { K("f") }
    private var j: HIDKey { K("j") }
    private var k: HIDKey { K("k") }
    private var z: HIDKey { K("z") }
    private var spc: HIDKey { K("spc") }
    private var lalt: HIDKey { K("lalt") }
    private var lmet: HIDKey { K("lmet") }
    private var c: HIDKey { K("c") }
    private var esc: HIDKey { K("esc") }
    private var left: HIDKey { K("left") }
    private var down: HIDKey { K("down") }
    private var ret: HIDKey { K("ret") }
    private var kp1: HIDKey { K("kp1") }
    private var f1: HIDKey { K("f1") }
    private var fn: HIDKey { Keys.fn }

    // MARK: - Keymap helpers

    private let source: [HIDKey] = ["caps", "a", "s", "d", "f", "j", "k", "l", ";", "spc", "lalt", "f1", "fn"]
        .map { KeyTable.key(named: $0)! }

    private func layer(_ name: String, _ bindings: [HIDKey: Action]) -> Layer {
        var actions = [Action?](repeating: nil, count: source.count)
        for (key, action) in bindings {
            actions[source.firstIndex(of: key)!] = action
        }
        return Layer(name: name, actions: actions)
    }

    /// defsrc `caps a s d f j k l ; spc lalt f1 fn`; base: caps = tap esc / hold extend, d = tap d / hold extend
    /// (hold-on-press), f = j (for ref-counting); extend: arrows, chord, ret, lalt = num; num: j = kp1.
    private func makeKeymap(priorIdleMs: Int = 0, functionRow: FunctionRowMode = .system) -> Keymap {
        var settings = Settings()
        settings.priorIdleMs = priorIdleMs
        settings.functionRow = functionRow
        let base = layer("base", [
            caps: .tapHold(.init(tap: .key(esc), hold: .layerWhileHeld(1))),
            d: .tapHold(.init(tap: .key(d), hold: .layerWhileHeld(1), resolution: .holdOnPress)),
            f: .key(j),
        ])
        let extend = layer("extend", [
            j: .key(left), k: .key(down), K("l"): .key(K("right")), K(";"): .key(K("end")),
            a: .chord(modifiers: [lmet], key: c),
            spc: .key(ret),
            lalt: .layerWhileHeld(2),
        ])
        let num = layer("num", [j: .key(kp1)])
        return Keymap(settings: settings, source: source, layers: [base, extend, num])
    }

    // MARK: - Event helpers

    private func dn(_ key: HIDKey, _ t: TimeInterval) -> KeyEvent { KeyEvent(key: key, isDown: true, time: t) }
    private func up(_ key: HIDKey, _ t: TimeInterval) -> KeyEvent { KeyEvent(key: key, isDown: false, time: t) }

    /// Feed events through `handle` in order and concatenate the outputs.
    private func type(_ engine: Engine, _ events: KeyEvent...) -> [OutputEvent] {
        var out: [OutputEvent] = []
        for e in events { out += engine.handle(e) }
        return out
    }

    // MARK: - 1. Permissive hold

    func testPermissiveHoldViaOtherKeyRelease() {
        let e = Engine(keymap: makeKeymap())
        let out = type(e, dn(caps, 0), dn(j, 0.05), up(j, 0.10), up(caps, 0.15))
        XCTAssertEqual(out, [.layerChanged([0, 1]), .press(left), .release(left), .layerChanged([0])])
        XCTAssertFalse(out.contains(.press(esc)))
        XCTAssertEqual(e.activeLayers, [0])
        XCTAssertTrue(e.heldOutputs.isEmpty)
    }

    // MARK: - 2. Tap

    func testTapBeforeTimeout() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(caps, 0)), [])
        XCTAssertEqual(type(e, up(caps, 0.1)), [.press(esc), .release(esc)])
        XCTAssertTrue(e.heldOutputs.isEmpty)
    }

    // MARK: - 3. Hold via timeout

    func testHoldViaTimeout() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(caps, 0)), [])
        XCTAssertEqual(e.tick(now: 0.1), [])
        XCTAssertEqual(e.tick(now: 0.25), [.layerChanged([0, 1])])
        XCTAssertEqual(type(e, dn(j, 0.3), up(j, 0.35)), [.press(left), .release(left)])
        XCTAssertEqual(type(e, up(caps, 0.4)), [.layerChanged([0])])
    }

    // MARK: - 4. Fast roll: release of a key that was already down does not decide

    func testReleaseOfPreviouslyHeldKeyDoesNotTriggerHold() {
        let e = Engine(keymap: makeKeymap())
        let out = type(e, dn(a, 0), dn(caps, 0.2), up(a, 0.25), up(caps, 0.3))
        XCTAssertEqual(out, [.press(a), .release(a), .press(esc), .release(esc)])
    }

    // MARK: - 5. Hold on press

    func testHoldOnPress() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(d, 0)), [])
        XCTAssertEqual(type(e, dn(j, 0.05)), [.layerChanged([0, 1]), .press(left)])
        XCTAssertEqual(type(e, up(j, 0.1), up(d, 0.15)), [.release(left), .layerChanged([0])])
        XCTAssertFalse(e.heldOutputs.contains(d))
    }

    // MARK: - 6. Tap-hold released before the other key → tap, order preserved

    func testTapWhenReleasedBeforeOtherKey() {
        let e = Engine(keymap: makeKeymap())
        let out = type(e, dn(caps, 0), dn(j, 0.05), up(caps, 0.1), up(j, 0.15))
        XCTAssertEqual(out, [.press(esc), .release(esc), .press(j), .release(j)])
    }

    // MARK: - 7. Prior idle

    func testPriorIdleForcesTap() {
        let e = Engine(keymap: makeKeymap(priorIdleMs: 120))
        XCTAssertEqual(type(e, dn(a, 0), up(a, 0.03)), [.press(a), .release(a)])
        XCTAssertEqual(type(e, dn(caps, 0.05)), [.press(esc)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(type(e, up(caps, 0.5)), [.release(esc)])
    }

    func testPriorIdleNotTriggeredAfterIdlePeriod() {
        let e = Engine(keymap: makeKeymap(priorIdleMs: 120))
        _ = type(e, dn(a, 0), up(a, 0.03))
        XCTAssertEqual(type(e, dn(caps, 0.5)), [])
        XCTAssertNotNil(e.nextDeadline)
    }

    // MARK: - 8. Quick tap

    func testQuickTapRepeatsTapAsHeld() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(caps, 0), up(caps, 0.05)), [.press(esc), .release(esc)])
        XCTAssertEqual(type(e, dn(caps, 0.1)), [.press(esc)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertTrue(e.heldOutputs.contains(esc))
        // Even after the hold timeout it is still the tap action being held.
        XCTAssertEqual(e.tick(now: 1.0), [])
        XCTAssertEqual(type(e, up(caps, 1.0)), [.release(esc)])
    }

    func testNoQuickTapAfterTapTimeout() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0), up(caps, 0.05))
        XCTAssertEqual(type(e, dn(caps, 0.5)), [])
        XCTAssertNotNil(e.nextDeadline)
    }

    // MARK: - 9. Held output stays held (auto-repeat model)

    func testHeldOutputStaysUntilRelease() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        _ = e.tick(now: 0.25)
        _ = type(e, dn(j, 0.3))
        XCTAssertTrue(e.heldOutputs.contains(left))
        _ = e.tick(now: 5)
        XCTAssertTrue(e.heldOutputs.contains(left))
        XCTAssertEqual(type(e, up(j, 5.1)), [.release(left)])
        XCTAssertFalse(e.heldOutputs.contains(left))
    }

    // MARK: - 10. Reload while a key is held

    func testReloadKeepsHeldBindings() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        _ = e.tick(now: 0.25)
        XCTAssertEqual(type(e, dn(j, 0.3)), [.press(left)])

        var newBase = layer("base", [j: .key(down)])
        newBase.actions[0] = .key(esc)
        let newMap = Keymap(source: source, layers: [newBase])
        XCTAssertEqual(e.load(newMap), [.layerChanged([0])])
        XCTAssertEqual(e.activeLayers, [0])
        XCTAssertEqual(e.keymap, newMap)

        XCTAssertEqual(type(e, up(j, 0.5)), [.release(left)])
        // Releasing caps (which had pushed layer 1) finds no instance to pop → nothing.
        XCTAssertEqual(type(e, up(caps, 0.6)), [])
        XCTAssertEqual(type(e, dn(j, 0.7), up(j, 0.8)), [.press(down), .release(down)])
    }

    func testReloadResolvesPendingAsTap() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        XCTAssertNotNil(e.nextDeadline)
        XCTAssertEqual(e.load(makeKeymap()), [.press(esc), .release(esc)])
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(type(e, up(caps, 0.1)), [])
    }

    // MARK: - 11. Layer stacking

    func testLayerStacking() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        XCTAssertEqual(e.tick(now: 0.25), [.layerChanged([0, 1])])
        XCTAssertEqual(type(e, dn(lalt, 0.3)), [.layerChanged([0, 1, 2])])
        XCTAssertEqual(type(e, dn(j, 0.35), up(j, 0.4)), [.press(kp1), .release(kp1)])
        XCTAssertEqual(type(e, up(lalt, 0.45)), [.layerChanged([0, 1])])
        XCTAssertEqual(type(e, dn(j, 0.5), up(j, 0.55)), [.press(left), .release(left)])
        XCTAssertEqual(type(e, up(caps, 0.6)), [.layerChanged([0])])
        XCTAssertEqual(type(e, dn(j, 0.7), up(j, 0.75)), [.press(j), .release(j)])
    }

    func testLayerReleaseRemovesMostRecentInstanceOnly() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        _ = e.tick(now: 0.25)
        // d on extend is transparent → falls to base tap-hold (hold-on-press) → pushes a second "1".
        XCTAssertEqual(type(e, dn(d, 0.3), dn(j, 0.35)), [.layerChanged([0, 1, 1]), .press(left)])
        XCTAssertEqual(type(e, up(j, 0.4), up(d, 0.45)), [.release(left), .layerChanged([0, 1])])
        XCTAssertEqual(e.activeLayers, [0, 1])
        XCTAssertEqual(type(e, up(caps, 0.5)), [.layerChanged([0])])
    }

    // MARK: - 12. Chord

    func testChord() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        _ = e.tick(now: 0.25)
        XCTAssertEqual(type(e, dn(a, 0.3)), [.press(lmet), .press(c)])
        XCTAssertEqual(type(e, up(a, 0.35)), [.release(c), .release(lmet)])
    }

    // MARK: - 13. Hardware-default function row

    func testFunctionRowSystemMediaDefault() {
        let e = Engine(keymap: makeKeymap(), systemFunctionKeysStandard: false)
        let brightnessDown = Keys.mediaFunctionRow[f1]!
        XCTAssertEqual(type(e, dn(f1, 0), up(f1, 0.1)), [.press(brightnessDown), .release(brightnessDown)])
    }

    func testFunctionRowWithFnHeld() {
        let e = Engine(keymap: makeKeymap(), systemFunctionKeysStandard: false)
        XCTAssertEqual(type(e, dn(fn, 0)), [.press(fn)])
        XCTAssertEqual(type(e, dn(f1, 0.1), up(f1, 0.2)), [.press(f1), .release(f1)])
        XCTAssertEqual(type(e, up(fn, 0.3)), [.release(fn)])
        // fn released → back to media.
        let brightnessDown = Keys.mediaFunctionRow[f1]!
        XCTAssertEqual(type(e, dn(f1, 0.4), up(f1, 0.5)), [.press(brightnessDown), .release(brightnessDown)])
    }

    func testFunctionRowSystemStandardKeys() {
        let e = Engine(keymap: makeKeymap(), systemFunctionKeysStandard: true)
        XCTAssertEqual(type(e, dn(f1, 0), up(f1, 0.1)), [.press(f1), .release(f1)])
        // With fn held the setting inverts → media.
        let brightnessDown = Keys.mediaFunctionRow[f1]!
        _ = type(e, dn(fn, 0.2))
        XCTAssertEqual(type(e, dn(f1, 0.3), up(f1, 0.4)), [.press(brightnessDown), .release(brightnessDown)])
    }

    func testFunctionRowExplicitModesIgnoreSystemSetting() {
        let media = Engine(keymap: makeKeymap(functionRow: .media), systemFunctionKeysStandard: true)
        XCTAssertEqual(type(media, dn(f1, 0)), [.press(Keys.mediaFunctionRow[f1]!)])
        let function = Engine(keymap: makeKeymap(functionRow: .function), systemFunctionKeysStandard: false)
        XCTAssertEqual(type(function, dn(f1, 0)), [.press(f1)])
    }

    func testFunctionKeyNotInDefsrcStillGetsMediaSemantics() {
        let e = Engine(keymap: makeKeymap(), systemFunctionKeysStandard: false)
        let f12 = Keys.functionKey(12)
        let volumeUp = Keys.mediaFunctionRow[f12]!
        XCTAssertEqual(type(e, dn(f12, 0), up(f12, 0.1)), [.press(volumeUp), .release(volumeUp)])
    }

    // MARK: - 14. Passthrough of keys not in defsrc

    func testKeyNotInDefsrcPassesThrough() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(z, 0), up(z, 0.1)), [.press(z), .release(z)])
    }

    func testTransparentKeyInDefsrcPassesThrough() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(k, 0), up(k, 0.1)), [.press(k), .release(k)])
    }

    // MARK: - 15. Ref-counting shared outputs

    func testRefCountingSharedOutput() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, dn(f, 0)), [.press(j)])
        XCTAssertEqual(type(e, dn(j, 0.1)), [])
        XCTAssertEqual(type(e, up(j, 0.2)), [])
        XCTAssertTrue(e.heldOutputs.contains(j))
        XCTAssertEqual(type(e, up(f, 0.3)), [.release(j)])
        XCTAssertTrue(e.heldOutputs.isEmpty)
    }

    // MARK: - 16. releaseAll

    func testReleaseAll() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        _ = e.tick(now: 0.25)
        _ = type(e, dn(lalt, 0.3), dn(a, 0.35), dn(z, 0.4), dn(d, 0.45))
        XCTAssertEqual(e.activeLayers, [0, 1, 2])
        XCTAssertNotNil(e.nextDeadline)
        XCTAssertEqual(e.heldOutputs, [lmet, c, z])

        let out = e.releaseAll()
        XCTAssertEqual(out.count, 4)
        for expected in [OutputEvent.release(lmet), .release(c), .release(z)] {
            XCTAssertTrue(out.contains(expected), "missing \(expected)")
        }
        XCTAssertEqual(out.last, .layerChanged([0]))
        XCTAssertTrue(e.heldOutputs.isEmpty)
        XCTAssertEqual(e.activeLayers, [0])
        XCTAssertNil(e.nextDeadline)
        // Subsequent releases of the physical keys are no-ops.
        XCTAssertEqual(type(e, up(a, 0.5), up(z, 0.55), up(lalt, 0.6), up(caps, 0.65), up(d, 0.7)), [])
    }

    // MARK: - 17. nextDeadline

    func testNextDeadline() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertNil(e.nextDeadline)
        _ = type(e, dn(caps, 1.0))
        XCTAssertEqual(e.nextDeadline, 1.2)
        _ = type(e, up(caps, 1.1))
        XCTAssertNil(e.nextDeadline)
        _ = type(e, dn(caps, 2.0))
        XCTAssertEqual(e.nextDeadline, 2.2)
        _ = e.tick(now: 2.2)
        XCTAssertNil(e.nextDeadline)
        XCTAssertEqual(e.activeLayers, [0, 1])
    }

    // MARK: - Extra: buffered events, macros, layer switch, timeout resolution

    func testEventAfterDeadlineFiresHoldFirst() {
        let e = Engine(keymap: makeKeymap())
        _ = type(e, dn(caps, 0))
        // No tick was called, but j arrives after the deadline → hold, then j on extend.
        XCTAssertEqual(type(e, dn(j, 0.3)), [.layerChanged([0, 1]), .press(left)])
    }

    func testTimeoutResolutionBuffersEverything() {
        let base = layer("base", [
            caps: .tapHold(.init(tap: .key(esc), hold: .layerWhileHeld(1), resolution: .timeout)),
        ])
        let extend = layer("extend", [j: .key(left)])
        let e = Engine(keymap: Keymap(source: source, layers: [base, extend]))
        // Press and release of j while pending do not decide; they are replayed after the tap.
        XCTAssertEqual(type(e, dn(caps, 0), dn(j, 0.05), up(j, 0.1)), [])
        XCTAssertEqual(type(e, up(caps, 0.15)), [.press(esc), .release(esc), .press(j), .release(j)])
    }

    func testSecondTapHoldWhilePendingIsBuffered() {
        let e = Engine(keymap: makeKeymap())
        // caps pending; d (tap-hold) pressed and released → permissive hold for caps; then d replayed:
        // on extend d is transparent → base tap-hold; its press+release within the buffer is a tap of `d`.
        let out = type(e, dn(caps, 0), dn(d, 0.05), up(d, 0.1), up(caps, 0.15))
        XCTAssertEqual(out, [.layerChanged([0, 1]), .press(d), .release(d), .layerChanged([0])])
    }

    func testMacroAndLayerSwitch() {
        let macro: Action = .macro([.key(a), .chord(modifiers: [lmet], key: c), .layerSwitch(1)])
        let base = layer("base", [k: macro])
        let extend = layer("extend", [j: .key(left)])
        let e = Engine(keymap: Keymap(source: source, layers: [base, extend]))
        XCTAssertEqual(type(e, dn(k, 0)), [
            .press(a), .release(a),
            .press(lmet), .press(c), .release(c), .release(lmet),
            .layerChanged([1]),
        ])
        XCTAssertEqual(type(e, up(k, 0.1)), [])
        XCTAssertEqual(e.activeLayers, [1])
        XCTAssertEqual(type(e, dn(j, 0.2), up(j, 0.3)), [.press(left), .release(left)])
    }

    func testBlockEmitsNothing() {
        let base = layer("base", [k: .block])
        let e = Engine(keymap: Keymap(source: source, layers: [base]))
        XCTAssertEqual(type(e, dn(k, 0), up(k, 0.1)), [])
    }

    func testReleaseWithoutPressIsDropped() {
        let e = Engine(keymap: makeKeymap())
        XCTAssertEqual(type(e, up(j, 0), up(z, 0.1)), [])
    }

    func testPerKeyTimeoutOverrides() {
        let base = layer("base", [
            caps: .tapHold(.init(tap: .key(esc), hold: .layerWhileHeld(1), holdTimeoutMs: 500)),
        ])
        let e = Engine(keymap: Keymap(source: source, layers: [base, layer("extend", [:])]))
        _ = type(e, dn(caps, 0))
        XCTAssertEqual(e.nextDeadline, 0.5)
        XCTAssertEqual(e.tick(now: 0.3), [])
        XCTAssertEqual(e.tick(now: 0.5), [.layerChanged([0, 1])])
    }
}
