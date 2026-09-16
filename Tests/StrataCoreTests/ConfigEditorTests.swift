import XCTest
@testable import StrataCore

final class ConfigEditorTests: XCTestCase {
    private let sample = """
    (defcfg
      tap-timeout 200
    )

    (defsrc
      esc  f1   f2
      caps a    b    c
    )

    (defalias
      ext (tap-hold esc (layer-while-held nav))   ;; hold for nav
      cpy M-c
    )

    (deflayer base
      esc  f1   f2
      @ext a    b    c
    )

    (deflayer nav
      _    brdn brup
      _    left down right
    )

    """

    private var doc: ConfigDocument { ConfigDocument(text: sample) }

    /// Asserts that `new` equals `old` with exactly `range` replaced (everything else byte-identical).
    private func assertOnlyChanged(_ old: String, _ new: String, range: Range<Int>, becomes replacement: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let o = Array(old.utf8), n = Array(new.utf8)
        XCTAssertEqual(Array(o[..<range.lowerBound]), Array(n[..<range.lowerBound]), "prefix changed", file: file, line: line)
        XCTAssertEqual(Array(o[range.upperBound...]), Array(n[(range.lowerBound + replacement.utf8.count)...]),
                       "suffix changed", file: file, line: line)
        XCTAssertEqual(String(decoding: n[range.lowerBound..<(range.lowerBound + replacement.utf8.count)], as: UTF8.self),
                       replacement, file: file, line: line)
    }

    private func line(_ n: Int, of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)[n - 1]
    }

    // MARK: - Queries

    func testStructuralQueries() {
        let d = doc
        XCTAssertEqual(d.layerNames, ["base", "nav"])
        XCTAssertEqual(d.sourceKeys.map(\.name), ["esc", "f1", "f2", "caps", "a", "b", "c"])
        XCTAssertEqual(d.sourceKeys[1].range, d.text.range(of: "f1").map { $0.lowerBound.utf16Offset(in: d.text)..<$0.upperBound.utf16Offset(in: d.text) })
        XCTAssertEqual(d.action(layer: "base", position: 3)?.text, "@ext")
        XCTAssertEqual(d.action(layer: "nav", position: 6)?.text, "right")
        XCTAssertNil(d.action(layer: "nav", position: 7))
        XCTAssertNil(d.action(layer: "nope", position: 0))
        XCTAssertEqual(d.aliases.map(\.name), ["ext", "cpy"])
        XCTAssertEqual(d.aliases[0].text, "(tap-hold esc (layer-while-held nav))")
        XCTAssertEqual(d.settings.map(\.key), ["tap-timeout"])
        XCTAssertEqual(d.settings.map(\.text), ["200"])
        XCTAssertEqual(d.gridLayout, GridLayout(rows: [[0, 1, 2], [3, 4, 5, 6]], firstRowInline: false,
                                                closeOnOwnLine: true, indent: "  "))
        XCTAssertEqual(d.gridWidths, [3, 4, 4, 4, 4, 4, 5])
    }

    // MARK: - setAction

    func testSetActionSameWidthChangesOnlyTheToken() throws {
        let d = doc
        let target = d.action(layer: "base", position: 1)!
        XCTAssertEqual(target.text, "f1")
        let edited = try d.setAction(layer: "base", position: 1, to: "f3")
        assertOnlyChanged(d.text, edited.text, range: target.range, becomes: "f3")
        XCTAssertEqual(edited.compile().errors, [])
    }

    func testSetActionShorterPadsToKeepFollowingTokensInPlace() throws {
        let d = doc
        let target = d.action(layer: "nav", position: 1)! // brdn
        let edited = try d.setAction(layer: "nav", position: 1, to: "_")
        assertOnlyChanged(d.text, edited.text, range: target.range, becomes: "_   ")
        XCTAssertEqual(line(21, of: edited.text), "  _    _    brup")
        XCTAssertEqual(edited.action(layer: "nav", position: 2)?.range, d.action(layer: "nav", position: 2)?.range)
    }

    func testSetActionShorterLastTokenOnLineIsNotPadded() throws {
        let d = doc
        let target = d.action(layer: "base", position: 6)! // c, end of line
        let edited = try d.setAction(layer: "base", position: 6, to: "_")
        assertOnlyChanged(d.text, edited.text, range: target.range, becomes: "_")
        XCTAssertEqual(line(17, of: edited.text), "  @ext a    b    _")
    }

    func testSetActionLongerConsumesSpareSpaces() throws {
        let d = doc
        let target = d.action(layer: "base", position: 4)! // "a" followed by 4 spaces
        let edited = try d.setAction(layer: "base", position: 4, to: "lsft")
        assertOnlyChanged(d.text, edited.text, range: target.range.lowerBound..<(target.range.upperBound + 3), becomes: "lsft")
        XCTAssertEqual(line(17, of: edited.text), "  @ext lsft b    c")
        XCTAssertEqual(edited.text.utf8.count, d.text.utf8.count)
        XCTAssertEqual(edited.action(layer: "base", position: 5)?.range, d.action(layer: "base", position: 5)?.range)
    }

    func testSetActionLongerThanSpareSpacesGrowsTheLine() throws {
        let d = doc
        let target = d.action(layer: "nav", position: 5)! // "down" followed by one space
        let edited = try d.setAction(layer: "nav", position: 5, to: "(layer-switch base)")
        assertOnlyChanged(d.text, edited.text, range: target.range, becomes: "(layer-switch base)")
        XCTAssertEqual(line(22, of: edited.text), "  _    left (layer-switch base) right")
        // With two spare spaces only two are consumed and one separator remains.
        let d2 = try d.setAction(layer: "base", position: 4, to: "lsftx")
        XCTAssertEqual(line(17, of: d2.text), "  @ext lsftx b    c")
        XCTAssertEqual(d2.compile().errors.count, 1) // lsftx is not a key; alignment still applied
    }

    func testSetActionErrors() {
        XCTAssertThrowsError(try doc.setAction(layer: "zzz", position: 0, to: "a")) { XCTAssertEqual($0 as? EditError, .unknownLayer("zzz")) }
        XCTAssertThrowsError(try doc.setAction(layer: "base", position: 42, to: "a")) { XCTAssertEqual($0 as? EditError, .positionOutOfRange(42)) }
    }

    // MARK: - Layers

    func testAddLayerProducesGridMatchingDefsrcLines() throws {
        let d = doc
        let added = try d.addLayer(name: "num")
        XCTAssertEqual(added.layerNames, ["base", "nav", "num"])
        XCTAssertTrue(added.text.hasPrefix(d.text))
        XCTAssertEqual(String(added.text.dropFirst(d.text.count)), "\n(deflayer num\n  _   _    _\n  _    _    _    _\n)\n")
        XCTAssertEqual(added.compile().errors, [])

        let copied = try d.addLayer(name: "nav2", copyFrom: "nav")
        XCTAssertEqual(String(copied.text.dropFirst(d.text.count)), "\n(deflayer nav2\n  _   brdn brup\n  _    left down right\n)\n")
        XCTAssertEqual(copied.actionTexts(layer: "nav2"), copied.actionTexts(layer: "nav"))

        XCTAssertThrowsError(try d.addLayer(name: "nav")) { XCTAssertEqual($0 as? EditError, .layerAlreadyExists("nav")) }
        XCTAssertThrowsError(try d.addLayer(name: "x", copyFrom: "nope")) { XCTAssertEqual($0 as? EditError, .unknownLayer("nope")) }
        XCTAssertThrowsError(try ConfigDocument(text: "(deflayer a)").addLayer(name: "b")) { XCTAssertEqual($0 as? EditError, .missingDefsrc) }
    }

    func testAddLayerFollowsInlineDefsrcStructure() throws {
        let d = ConfigDocument(text: "(defsrc a b c)\n(deflayer base a b c)")
        let added = try d.addLayer(name: "two")
        XCTAssertEqual(added.text, "(defsrc a b c)\n(deflayer base a b c)\n\n(deflayer two _ _ _)\n")
        XCTAssertEqual(added.compile().errors, [])
    }

    func testRenameLayerUpdatesReferences() throws {
        let d = doc
        let renamed = try d.renameLayer("nav", to: "navigation")
        XCTAssertEqual(renamed.layerNames, ["base", "navigation"])
        XCTAssertEqual(renamed.aliases[0].text, "(tap-hold esc (layer-while-held navigation))")
        XCTAssertEqual(renamed.compile().errors, [])
        XCTAssertEqual(renamed.text.utf8.count, d.text.utf8.count + 2 * "igation".utf8.count)
        XCTAssertThrowsError(try d.renameLayer("nav", to: "base")) { XCTAssertEqual($0 as? EditError, .layerAlreadyExists("base")) }
        XCTAssertThrowsError(try d.renameLayer("zzz", to: "y")) { XCTAssertEqual($0 as? EditError, .unknownLayer("zzz")) }
    }

    func testDeleteLayerReportsDanglingReferences() throws {
        let d = doc
        let (deleted, diagnostics) = try d.deleteLayer("nav")
        let cut = d.text.range(of: "\n(deflayer nav")!
        XCTAssertEqual(deleted.text, String(d.text[..<cut.lowerBound]))
        XCTAssertEqual(deleted.layerNames, ["base"])
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
        XCTAssertEqual(diagnostics[0].location, SourceLocation(line: 11, column: 39))
        XCTAssertEqual(deleted.sourceMap.text(in: diagnostics[0].range), "nav")

        let (deletedBase, none) = try d.deleteLayer("base")
        XCTAssertEqual(none, [])
        XCTAssertEqual(deletedBase.layerNames, ["nav"])
        XCTAssertFalse(deletedBase.text.contains("\n\n\n"))
        XCTAssertThrowsError(try d.deleteLayer("zzz"))
    }

    func testRealignRewritesWhitespaceOnly() throws {
        let messy = """
        (defsrc
          esc  f1   f2
          caps a    b    c
        )
        (deflayer base
          _ brdn brup ;; row one
                _ left     down right
        )

        """
        let d = ConfigDocument(text: messy)
        let aligned = try d.realign(layer: "base")
        XCTAssertEqual(aligned.text, """
        (defsrc
          esc  f1   f2
          caps a    b    c
        )
        (deflayer base
          _   brdn brup ;; row one
          _    left down right
        )

        """)
        XCTAssertEqual(aligned.actionTexts(layer: "base"), d.actionTexts(layer: "base"))
        XCTAssertEqual(try aligned.realign(layer: "base").text, aligned.text)
    }

    // MARK: - Settings

    func testSetSettingReplaceAddAndCreate() {
        let d = doc
        let replaced = d.setSetting(key: "tap-timeout", to: "150")
        assertOnlyChanged(d.text, replaced.text, range: d.settings[0].range, becomes: "150")
        let added = d.setSetting(key: "hold-timeout", to: "250")
        XCTAssertTrue(added.text.hasPrefix("(defcfg\n  tap-timeout 200\n  hold-timeout 250\n)\n"))
        XCTAssertEqual(added.settings.map(\.key), ["tap-timeout", "hold-timeout"])
        XCTAssertEqual(added.compile().errors, [])

        let bare = ConfigDocument(text: ";; header\n(defsrc a)\n(deflayer base a)\n")
        let created = bare.setSetting(key: "fn-row", to: "media")
        XCTAssertEqual(created.text, ";; header\n(defcfg\n  fn-row media\n)\n\n(defsrc a)\n(deflayer base a)\n")
        XCTAssertEqual(created.compile().keymap?.settings.functionRow, .media)
        XCTAssertEqual(ConfigDocument(text: "").setSetting(key: "fn-row", to: "media").text, "(defcfg\n  fn-row media\n)\n")
        let inline = ConfigDocument(text: "(defcfg fn-row media)").setSetting(key: "tap-timeout", to: "5")
        XCTAssertEqual(inline.text, "(defcfg fn-row media tap-timeout 5)")
    }

    // MARK: - Aliases

    func testSetAliasReplaceAddAndCreate() {
        let d = doc
        let replaced = d.setAlias(name: "cpy", to: "M-x")
        assertOnlyChanged(d.text, replaced.text, range: d.aliases[1].range, becomes: "M-x")
        let added = d.setAlias(name: "pst", to: "M-v")
        XCTAssertTrue(added.text.contains("  cpy M-c\n  pst M-v\n)\n"))
        XCTAssertEqual(added.aliases.map(\.name), ["ext", "cpy", "pst"])
        XCTAssertEqual(added.compile().errors, [])

        let bare = ConfigDocument(text: "(defsrc a)\n\n(deflayer base @x)\n")
        let created = bare.setAlias(name: "x", to: "M-c")
        XCTAssertEqual(created.text, "(defsrc a)\n\n(defalias\n  x M-c\n)\n\n(deflayer base @x)\n")
        XCTAssertEqual(created.compile().errors, [])
    }

    func testRemoveAlias() throws {
        let d = doc
        let removed = try d.removeAlias(name: "cpy")
        XCTAssertEqual(removed.text, d.text.replacingOccurrences(of: "\n  cpy M-c", with: ""))
        XCTAssertEqual(removed.aliases.map(\.name), ["ext"])
        let inline = try ConfigDocument(text: "(defalias a M-c  b M-v)").removeAlias(name: "b")
        XCTAssertEqual(inline.text, "(defalias a M-c)")
        XCTAssertThrowsError(try d.removeAlias(name: "zzz")) { XCTAssertEqual($0 as? EditError, .unknownAlias("zzz")) }
    }

    // MARK: - Formatter

    func testDefaultConfigCompilesCleanly() {
        let keys = ["esc", "f1", "f2", "grv", "1", "2", "bspc", "tab", "q", "w", "e", "\\", "caps", "a", "s", "d", "ret",
                    "lsft", "z", "x", "c", "rsft", "fn", "lctl", "lalt", "lmet", "spc", "rmet", "left", "down", "up", "right"]
        let text = Formatter.defaultConfig(sourceKeys: keys)
        let d = ConfigDocument(text: text)
        XCTAssertEqual(d.text, text)
        let result = d.compile()
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.keymap?.layers.map(\.name), ["base", "extend"])
        XCTAssertEqual(result.keymap?.source.count, keys.count)
        XCTAssertEqual(d.gridLayout?.rows.count, 6)
        let caps = result.keymap!.positionByKey[Keys.capsLock]!
        XCTAssertEqual(result.keymap?.layers[0].actions[caps],
                       .tapHold(Action.TapHold(tap: .key(Keys.escape), hold: .layerWhileHeld(1))))
    }
}
