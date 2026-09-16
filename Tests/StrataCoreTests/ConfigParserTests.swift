import XCTest
@testable import StrataCore

final class ConfigParserTests: XCTestCase {
    private let roundTripInputs: [String] = [
        "",
        "   \n\t\n",
        ";; just a comment",
        "(defsrc a b c)",
        "(defsrc\n  a  b\tc\r\n)\n",
        "(defsrc ; a) ;; the single semicolon is a key\n",
        "(deflayer x \\ \\\\ _ XX)",
        "#| block\n comment |# (defcfg exclude-devices (\"Foo \\\"Bar\\\"\" baz))\n;; tail",
        "(a (b (c)) #| nested #| inner |# still |# d)  \n\n",
        "(defsrc é ü ✓)   ;; unicode atoms\n",
        Fixtures.kmonadColemak,
    ]

    func testRoundTripReproducesInputExactly() {
        for input in roundTripInputs {
            let (tree, diagnostics) = Parser.parse(input)
            XCTAssertEqual(tree.text, input, "CST re-serialisation differs for: \(input.debugDescription)")
            XCTAssertEqual(ConfigDocument(text: input).text, input)
            XCTAssertTrue(diagnostics.isEmpty, "unexpected diagnostics for \(input.debugDescription): \(diagnostics)")
        }
    }

    func testRoundTripOfMalformedInputIsStillLossless() {
        for input in ["(defsrc a b", "(defsrc a))", "\"unterminated", "#| never closed", ")))(((", "(((a) b"] {
            let (tree, diagnostics) = Parser.parse(input)
            XCTAssertEqual(tree.text, input)
            XCTAssertFalse(diagnostics.isEmpty, "expected a diagnostic for \(input.debugDescription)")
        }
    }

    func testSingleSemicolonIsAnAtomAndDoubleIsAComment() {
        let (tree, _) = Parser.parse("(defsrc ; a) ;; comment\n(x)")
        let list = tree.nodes[0].asList!
        XCTAssertEqual(list.children.map(\.tokenText), ["defsrc", ";", "a"])
        XCTAssertEqual(tree.nodes[1].leadingTrivia, " ;; comment\n")
    }

    func testBlockCommentsNestAndBecomeTrivia() {
        let (tree, diagnostics) = Parser.parse("#| a #| b |# c |#(x)")
        XCTAssertTrue(diagnostics.isEmpty)
        XCTAssertEqual(tree.nodes[0].leadingTrivia, "#| a #| b |# c |#")
        XCTAssertEqual(tree.nodes[0].tokenText, "(x)")
    }

    func testStringEscapes() {
        let (tree, _) = Parser.parse("(\"a \\\"quoted\\\" \\\\ b\")")
        guard case .string(let s)? = tree.nodes[0].asList?.children.first else { return XCTFail("expected string") }
        XCTAssertEqual(s.value, "a \"quoted\" \\ b")
        XCTAssertEqual(s.rawText, "\"a \\\"quoted\\\" \\\\ b\"")
    }

    func testByteRangesAndTokenText() {
        let text = "(defsrc\n  esc  f1)"
        let (tree, _) = Parser.parse(text)
        let list = tree.nodes[0].asList!
        XCTAssertEqual(list.openRange, 0..<1)
        XCTAssertEqual(list.closeRange, 17..<18)
        XCTAssertEqual(list.range, 0..<18)
        let esc = list.children[1]
        XCTAssertEqual(esc.range, 10..<13)
        XCTAssertEqual(esc.leadingTrivia, "\n  ")
        XCTAssertEqual(String(decoding: Array(text.utf8)[esc.range], as: UTF8.self), "esc")
    }

    func testSourceMapLinesAndUnicodeColumns() {
        let text = "ab\n(défsrc x)\n\nz"
        let map = SourceMap(text: text)
        XCTAssertEqual(map.lineCount, 4)
        XCTAssertEqual(map.location(ofByte: 0), SourceLocation(line: 1, column: 1))
        XCTAssertEqual(map.location(ofByte: 3), SourceLocation(line: 2, column: 1))
        // "x" is after "(défsrc " — é is two bytes but one column.
        let xOffset = Array(text.utf8).firstIndex(of: UInt8(ascii: "x"))!
        XCTAssertEqual(map.location(ofByte: xOffset), SourceLocation(line: 2, column: 9))
        XCTAssertEqual(map.location(ofByte: text.utf8.count - 1), SourceLocation(line: 4, column: 1))
        XCTAssertEqual(map.lineRange(1), 3..<(3 + "(défsrc x)".utf8.count))
        XCTAssertEqual(map.text(in: map.lineRange(1)), "(défsrc x)")
    }

    func testUnbalancedParensPositions() {
        let (_, unclosed) = Parser.parse("(defsrc a\n  (deflayer b")
        XCTAssertEqual(unclosed.count, 2)
        XCTAssertEqual(unclosed.map { "\($0.line):\($0.column)" }.sorted(), ["1:1", "2:3"])
        XCTAssertTrue(unclosed.allSatisfy { $0.message.contains("unclosed") })

        let (tree, stray) = Parser.parse("(defsrc a)\n  )")
        XCTAssertEqual(stray.count, 1)
        XCTAssertEqual(stray[0].line, 2)
        XCTAssertEqual(stray[0].column, 3)
        XCTAssertTrue(stray[0].message.contains("unexpected ')'"))
        XCTAssertEqual(tree.text, "(defsrc a)\n  )")
    }

    func testUnterminatedStringAndComment() {
        let (_, s) = Parser.parse("(x \"abc")
        XCTAssertEqual(s.count, 2) // unterminated string + unclosed list
        XCTAssertTrue(s.contains { $0.message.contains("unterminated string") && $0.column == 4 })
        let (_, c) = Parser.parse("(x)\n#| oops")
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c[0].line, 2)
        XCTAssertTrue(c[0].message.contains("block comment"))
    }

    func testDoesNotCrashOnGarbage() {
        // Deterministic LCG so failures are reproducible.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        let alphabet = Array("()\"\\;#| \n\tabc_@-")
        for _ in 0..<300 {
            let s = String((0..<next(40)).map { _ in alphabet[next(alphabet.count)] })
            let (tree, _) = Parser.parse(s)
            XCTAssertEqual(tree.text, s)
            _ = compile(text: s)
        }
    }

    func testFormsLookupIsCaseInsensitive() {
        let (tree, _) = Parser.parse("(DefSrc a) (defsrc b)")
        XCTAssertEqual(tree.forms(named: "defsrc").count, 2)
    }
}
