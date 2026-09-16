import XCTest
@testable import StrataCore

final class ConfigCompilerTests: XCTestCase {
    private func key(_ name: String) -> HIDKey { KeyTable.key(named: name)! }

    private func compileOK(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Keymap? {
        let result = compile(text: text)
        XCTAssertTrue(result.errors.isEmpty, "unexpected errors: \(result.errors)", file: file, line: line)
        XCTAssertNotNil(result.keymap, file: file, line: line)
        return result.keymap
    }

    private func firstError(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Diagnostic? {
        let result = compile(text: text)
        XCTAssertNil(result.keymap, "expected compilation to fail", file: file, line: line)
        XCTAssertFalse(result.errors.isEmpty, "expected an error", file: file, line: line)
        return result.errors.first
    }

    private let minimal = "(defsrc a b c)\n(deflayer base a b c)\n"

    // MARK: - kmonad fixture

    func testKmonadFileCompilesWithOnlyWarnings() {
        let result = compile(text: Fixtures.kmonadColemak)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.warnings.count, 3)
        XCTAssertTrue(result.warnings.allSatisfy { $0.message.hasPrefix("unknown defcfg key") })
        XCTAssertEqual(result.warnings.map(\.message).sorted(),
                       ["unknown defcfg key 'fallthrough' (ignored)", "unknown defcfg key 'input' (ignored)",
                        "unknown defcfg key 'output' (ignored)"])
        guard let keymap = result.keymap else { return XCTFail("no keymap") }
        XCTAssertEqual(keymap.layers.map(\.name), ["colemak-dh", "extend", "numpad"])
        XCTAssertEqual(keymap.source.count, 76)
        XCTAssertTrue(keymap.layers.allSatisfy { $0.actions.count == 76 })

        let caps = keymap.positionByKey[Keys.capsLock]!
        XCTAssertEqual(caps, 41)
        XCTAssertEqual(keymap.layers[0].actions[caps],
                       .tapHold(Action.TapHold(tap: .key(Keys.escape), hold: .layerWhileHeld(1),
                                               holdTimeoutMs: 150, resolution: .permissive)))
        // @cpy on extend sits at the physical `x` position (z x c → cut copy paste).
        let x = keymap.positionByKey[key("x")]!
        XCTAssertEqual(keymap.layers[1].actions[x], .chord(modifiers: [Keys.leftCommand], key: key("c")))
        // `_` transparent (esc position on base).
        XCTAssertEqual(keymap.layers[0].actions[0], .transparent)
        // `\\` on base at the physical backslash position.
        let bksl = keymap.positionByKey[key("\\")]!
        XCTAssertEqual(keymap.layers[0].actions[bksl], .key(key("\\")))
        // kmonad shifted symbols on the numpad layer: `*` and `+`.
        let nine = keymap.positionByKey[key("9")]!
        XCTAssertEqual(keymap.layers[2].actions[nine], .chord(modifiers: [Keys.leftShift], key: key("8")))
        // @bk resolves `Back` case-insensitively.
        let w = keymap.positionByKey[key("w")]!
        XCTAssertEqual(keymap.layers[1].actions[w], .key(key("back")))
        // `(layer-toggle numpad)` on the extend layer.
        let lalt = keymap.positionByKey[Keys.leftOption]!
        XCTAssertEqual(keymap.layers[1].actions[lalt], .layerWhileHeld(2))
    }

    // MARK: - defcfg

    func testSettings() {
        let text = """
        (defcfg tap-hold-resolution hold-on-press tap-timeout 150 hold-timeout 250 prior-idle 90
                fn-row media exclude-devices ("Keychron K2" "Magic Keyboard"))
        """ + minimal
        let k = compileOK(text)
        XCTAssertEqual(k?.settings.resolution, .holdOnPress)
        XCTAssertEqual(k?.settings.tapTimeoutMs, 150)
        XCTAssertEqual(k?.settings.holdTimeoutMs, 250)
        XCTAssertEqual(k?.settings.priorIdleMs, 90)
        XCTAssertEqual(k?.settings.functionRow, .media)
        XCTAssertEqual(k?.settings.excludeDevices, ["Keychron K2", "Magic Keyboard"])
        XCTAssertEqual(compileOK("(defcfg exclude-devices Foo)" + minimal)?.settings.excludeDevices, ["Foo"])
        XCTAssertEqual(compileOK(minimal)?.settings, Settings())
    }

    func testSettingsErrorsAndWarnings() {
        XCTAssertEqual(firstError("(defcfg tap-hold-resolution sometimes)" + minimal)?.column, 29)
        XCTAssertTrue(firstError("(defcfg tap-timeout fast)" + minimal)!.message.contains("milliseconds"))
        XCTAssertTrue(firstError("(defcfg fn-row)" + minimal)!.message.contains("has no value"))
        let r = compile(text: "(defcfg allow-cmd true cmp-seq ralt)" + minimal)
        XCTAssertNotNil(r.keymap)
        XCTAssertEqual(r.warnings.count, 2)
    }

    // MARK: - actions

    func testAtomActions() {
        let k = compileOK("(defsrc a b c d e f)\n(deflayer base _ XX none nop \\\\ *)")!
        XCTAssertEqual(k.layers[0].actions, [.transparent, .block, .block, .block, .key(key("\\")),
                                             .chord(modifiers: [Keys.leftShift], key: key("8"))])
    }

    func testChordShorthandAndExplicitChords() {
        let k = compileOK("(defsrc a b c d e f g)\n(deflayer base M-c C-S-tab RA-x M-lsft S-* (chord lmet lsft 4) M-S-4)")!
        XCTAssertEqual(k.layers[0].actions[0], .chord(modifiers: [Keys.leftCommand], key: key("c")))
        XCTAssertEqual(k.layers[0].actions[1], .chord(modifiers: [Keys.leftControl, Keys.leftShift], key: key("tab")))
        XCTAssertEqual(k.layers[0].actions[2], .chord(modifiers: [Keys.rightOption], key: key("x")))
        XCTAssertEqual(k.layers[0].actions[3], .chord(modifiers: [Keys.leftCommand], key: Keys.leftShift))
        XCTAssertEqual(k.layers[0].actions[4], .chord(modifiers: [Keys.leftShift], key: key("8")))
        XCTAssertEqual(k.layers[0].actions[5], .chord(modifiers: [Keys.leftCommand, Keys.leftShift], key: key("4")))
        XCTAssertEqual(k.layers[0].actions[6], .chord(modifiers: [Keys.leftCommand, Keys.leftShift], key: key("4")))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer base M-nope)")!.message.hasPrefix("unknown key 'nope' in chord 'M-nope'"))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer base (chord a b))")!.message.contains("not a modifier"))
    }

    func testLayerActions() {
        let k = compileOK("(defsrc a b c)\n(deflayer base (layer-while-held nav) (layer-toggle nav) (layer-switch base))\n(deflayer nav _ _ _)")!
        XCTAssertEqual(k.layers[0].actions, [.layerWhileHeld(1), .layerWhileHeld(1), .layerSwitch(0)])
        let e = firstError("(defsrc a)\n(deflayer base (layer-while-held nowhere))")!
        XCTAssertEqual(e.message, "unknown layer 'nowhere'")
        XCTAssertEqual(e.location, SourceLocation(line: 2, column: 34))
    }

    func testTapHoldForms() {
        let text = """
        (defsrc a b c d e f)
        (deflayer base (tap-hold a lctl) (tap-hold 150 a lctl) (tap-hold 100 250 a lctl)
                       (tap-hold-press a lctl) (tap-hold-next-release 150 esc (layer-toggle base)) (tap-hold-timeout M-c XX))
        """
        let k = compileOK(text)!
        let th = { (a: Action) -> Action.TapHold? in if case .tapHold(let t) = a { return t } else { return nil } }
        XCTAssertEqual(th(k.layers[0].actions[0]!),
                       Action.TapHold(tap: .key(key("a")), hold: .key(Keys.leftControl)))
        XCTAssertEqual(th(k.layers[0].actions[1]!)?.holdTimeoutMs, 150)
        XCTAssertNil(th(k.layers[0].actions[1]!)?.tapTimeoutMs)
        XCTAssertEqual(th(k.layers[0].actions[2]!)?.tapTimeoutMs, 100)
        XCTAssertEqual(th(k.layers[0].actions[2]!)?.holdTimeoutMs, 250)
        XCTAssertNil(th(k.layers[0].actions[2]!)?.resolution)
        XCTAssertEqual(th(k.layers[0].actions[3]!)?.resolution, .holdOnPress)
        XCTAssertEqual(th(k.layers[0].actions[4]!)?.resolution, .permissive)
        XCTAssertEqual(th(k.layers[0].actions[4]!)?.hold, .layerWhileHeld(0))
        XCTAssertEqual(th(k.layers[0].actions[5]!)?.resolution, .timeout)
        XCTAssertEqual(th(k.layers[0].actions[5]!)?.tap, .chord(modifiers: [Keys.leftCommand], key: key("c")))
        XCTAssertEqual(compileOK("(defsrc a)\n(deflayer base (tap-hold-release a b))")?.layers[0].actions[0].flatMap(th)?.resolution, .permissive)
        XCTAssertEqual(compileOK("(defsrc a)\n(deflayer base (tap-hold-next a b))")?.layers[0].actions[0].flatMap(th)?.resolution, .permissive)
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer base (tap-hold a))")!.message.contains("expects 2 to 4 arguments"))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer base (tap-hold x a b))")!.message.contains("expected hold timeout"))
    }

    func testNestedTapHoldIsAnError() {
        let e = firstError("(defsrc a)\n(deflayer base (tap-hold a (tap-hold b c)))")!
        XCTAssertEqual(e.message, "nested tap-hold is not allowed")
        XCTAssertEqual(e.location, SourceLocation(line: 2, column: 28))
        let viaAlias = firstError("(defsrc a)\n(defalias th (tap-hold b c))\n(deflayer base (tap-hold a @th))")!
        XCTAssertEqual(viaAlias.message, "nested tap-hold is not allowed")
        XCTAssertEqual(viaAlias.location, SourceLocation(line: 3, column: 28))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer base (macro a (tap-hold b c)))")!.message.contains("inside a macro"))
    }

    func testMacro() {
        let k = compileOK("(defsrc a)\n(deflayer base (macro h M-i (chord lsft j)))")!
        XCTAssertEqual(k.layers[0].actions[0], .macro([.key(key("h")), .chord(modifiers: [Keys.leftCommand], key: key("i")),
                                                       .chord(modifiers: [Keys.leftShift], key: key("j"))]))
        XCTAssertNotNil(firstError("(defsrc a)\n(deflayer base (macro))"))
    }

    // MARK: - aliases

    func testAliasesResolveForwardBackwardAndDetectCycles() {
        let k = compileOK("(defsrc a b)\n(defalias one @two two M-c)\n(deflayer base @one @two)\n(defalias late (layer-switch base))")!
        XCTAssertEqual(k.layers[0].actions, [.chord(modifiers: [Keys.leftCommand], key: key("c")),
                                             .chord(modifiers: [Keys.leftCommand], key: key("c"))])
        let cycle = firstError("(defsrc a)\n(defalias x @y y @x)\n(deflayer base @x)")!
        XCTAssertTrue(cycle.message.contains("cycle"), cycle.message)
        let unknown = firstError("(defsrc a)\n(defalias cpy M-c)\n(deflayer base @cpyy)")!
        XCTAssertEqual(unknown.message, "unknown alias '@cpyy' (did you mean '@cpy'?)")
        XCTAssertEqual(unknown.location, SourceLocation(line: 3, column: 16))
        XCTAssertTrue(firstError("(defsrc a)\n(defalias x M-c x M-v)\n(deflayer base @x)")!.message.contains("duplicate alias"))
        XCTAssertTrue(firstError("(defsrc a)\n(defalias x)\n(deflayer base a)")!.message.contains("has no action"))
        // Unreferenced aliases are still validated.
        XCTAssertTrue(firstError("(defsrc a)\n(defalias bad nokey)\n(deflayer base a)")!.message.hasPrefix("unknown key 'nokey'"))
    }

    // MARK: - validation

    func testLayerArityErrorPointsAtLayerName() {
        let e = firstError("(defsrc a b c)\n(deflayer base a b)\n")!
        XCTAssertEqual(e.message, "layer 'base' has 2 actions but defsrc has 3 keys")
        XCTAssertEqual(e.location, SourceLocation(line: 2, column: 11))
        XCTAssertEqual(e.range, 25..<29)
    }

    func testUnknownKeyWithSuggestion() {
        let e = firstError("(defsrc a)\n(deflayer base\n  capslok)")!
        XCTAssertEqual(e.message, "unknown key 'capslok' (did you mean 'capslock'?)")
        XCTAssertEqual(e.location, SourceLocation(line: 3, column: 3))
        XCTAssertEqual(e.description(filename: "keymap.kbd"), "keymap.kbd:3:3: error: unknown key 'capslok' (did you mean 'capslock'?)")
        XCTAssertEqual(e.description, "3:3: error: unknown key 'capslok' (did you mean 'capslock'?)")
        XCTAssertEqual(firstError("(defsrc qqqqqq)\n(deflayer base a)")?.message, "unknown key 'qqqqqq'")
    }

    func testStructuralErrors() {
        XCTAssertEqual(firstError("(deflayer base a)")?.message, "missing (defsrc …) form")
        XCTAssertTrue(firstError("(defsrc a)")!.message.hasPrefix("no (deflayer"))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer x a)\n(deflayer x a)")!.message.contains("duplicate layer name 'x'"))
        XCTAssertTrue(firstError("(defsrc a)\n(defsrc b)\n(deflayer x a)")!.message.contains("duplicate (defsrc"))
        XCTAssertTrue(firstError("(defsrc (a))\n(deflayer x a)")!.message.contains("plain key names"))
        XCTAssertTrue(firstError("(defsrc a)\n(defwhat)\n(deflayer x a)")!.message.contains("unknown form 'defwhat'"))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer x a)\nstray")!.message.contains("expected a form"))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer x (frobnicate a))")!.message.contains("unknown action 'frobnicate'"))
        XCTAssertTrue(firstError("(defsrc a)\n(deflayer x \"a\")")!.message.contains("unexpected string"))
    }

    func testDuplicateSourceKeyIsAWarning() {
        let r = compile(text: "(defsrc a a)\n(deflayer base b c)")
        XCTAssertNotNil(r.keymap)
        XCTAssertEqual(r.warnings.count, 1)
        XCTAssertTrue(r.warnings[0].message.contains("duplicate key 'a'"))
        XCTAssertEqual(r.keymap?.source.count, 2)
    }

    func testUnbalancedParensFailCompilation() {
        let r = compile(text: "(defsrc a\n(deflayer base a)")
        XCTAssertNil(r.keymap)
        XCTAssertTrue(r.errors.contains { $0.message.contains("unclosed") && $0.line == 1 && $0.column == 1 })
        let r2 = compile(text: "(defsrc a)\n(deflayer base a))")
        XCTAssertNil(r2.keymap)
        XCTAssertEqual(r2.errors.count, 1)
        XCTAssertEqual(r2.errors[0].location, SourceLocation(line: 2, column: 18))
    }

    func testDocumentCompileMatchesFreeFunction() {
        let doc = ConfigDocument(text: Fixtures.kmonadColemak)
        XCTAssertEqual(doc.compile().keymap, compile(text: Fixtures.kmonadColemak).keymap)
    }
}
