import XCTest
@testable import StrataCore

final class DeviceExclusionsTests: XCTestCase {
    func testMatchesExactProductName() {
        XCTAssertTrue(DeviceExclusions.matches(product: "Keychron K2", excludes: ["Keychron K2"]))
        XCTAssertTrue(DeviceExclusions.matches(product: "Keychron K2", excludes: ["Magic Keyboard", "Keychron K2"]))
        XCTAssertFalse(DeviceExclusions.matches(product: "Keychron K2", excludes: []))
        XCTAssertFalse(DeviceExclusions.matches(product: "Keychron K2", excludes: ["Magic Keyboard"]))
    }

    func testMatchIgnoresCase() {
        XCTAssertTrue(DeviceExclusions.matches(product: "keychron k2", excludes: ["Keychron K2"]))
        XCTAssertTrue(DeviceExclusions.matches(product: "KEYCHRON K2", excludes: ["keychron k2"]))
    }

    func testPartialNameDoesNotMatch() {
        XCTAssertFalse(DeviceExclusions.matches(product: "Keychron K2 Pro", excludes: ["Keychron K2"]))
        XCTAssertFalse(DeviceExclusions.matches(product: "Keychron K2", excludes: ["Keychron"]))
    }

    func testEmptyProductNameNeverMatches() {
        XCTAssertFalse(DeviceExclusions.matches(product: "", excludes: [""]))
    }

    func testDeviceListFormattingRoundTripsThroughTheCompiler() {
        XCTAssertEqual(Formatter.deviceList([]), "()")
        XCTAssertEqual(Formatter.deviceList(["Keychron K2"]), "(\"Keychron K2\")")
        XCTAssertEqual(Formatter.deviceList(["A B", "C\"D", "E\\F"]), "(\"A B\" \"C\\\"D\" \"E\\\\F\")")

        let text = "(defcfg exclude-devices \(Formatter.deviceList(["A B", "C\"D", "E\\F"])))\n(defsrc a)\n(deflayer base a)\n"
        let result = compile(text: text)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(result.keymap?.settings.excludeDevices, ["A B", "C\"D", "E\\F"])

        XCTAssertEqual(compile(text: "(defcfg exclude-devices \(Formatter.deviceList([])))\n(defsrc a)\n(deflayer base a)\n").keymap?.settings.excludeDevices, [])
    }
}
