import XCTest
@testable import LorisListKit

final class ListLogicTests: XCTestCase {

    // MARK: Colours

    func testHexNormalizing() {
        XCTAssertEqual(HexColor.normalize("ff9900"), "ff9900")
        XCTAssertEqual(HexColor.normalize("#FF9900"), "ff9900")
        XCTAssertEqual(HexColor.normalize("  3366CC "), "3366cc")
        XCTAssertNil(HexColor.normalize("ff990"))
        XCTAssertNil(HexColor.normalize("gg9900"))
        XCTAssertNil(HexColor.normalize(""))
    }

    func testRGBValues() throws {
        let orange = try XCTUnwrap(HexColor.rgb("ff9900"))
        XCTAssertEqual(orange.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(orange.green, 0.6, accuracy: 0.001)
        XCTAssertEqual(orange.blue, 0.0, accuracy: 0.001)
        XCTAssertNil(HexColor.rgb("nope"))
    }

    func testReadableTextColour() {
        XCTAssertTrue(HexColor.prefersDarkText(on: "ff9900"), "orange wants dark text")
        XCTAssertTrue(HexColor.prefersDarkText(on: "ffffff"))
        XCTAssertTrue(HexColor.prefersDarkText(on: "ffff00"))
        XCTAssertFalse(HexColor.prefersDarkText(on: "3366cc"), "blue wants white text")
        XCTAssertFalse(HexColor.prefersDarkText(on: "000000"))
        XCTAssertFalse(HexColor.prefersDarkText(on: "8b0000"))
    }

    // MARK: Items

    func testItemCountParsing() {
        XCTAssertEqual(ItemInput.parseCount("3"), 3)
        XCTAssertEqual(ItemInput.parseCount(" 12 "), 12)
        XCTAssertNil(ItemInput.parseCount(""))
        XCTAssertNil(ItemInput.parseCount("0"), "the server needs at least 1")
        XCTAssertNil(ItemInput.parseCount("-2"))
        XCTAssertNil(ItemInput.parseCount("two"))
        XCTAssertNil(ItemInput.parseCount("1.5"))
    }

    func testItemNamesAreTrimmedAndCapped() {
        XCTAssertEqual(ItemInput.cleanName("  Milk \n"), "Milk")
        XCTAssertEqual(ItemInput.cleanName(String(repeating: "a", count: 150)).count, 100)
        XCTAssertEqual(ItemInput.cleanName("   "), "")
    }

    func testSuggestionsPutPrefixMatchesFirstAndSkipExactMatch() {
        let names = ["Almond milk", "Milk", "Buttermilk", "Milkshake mix", "Bread", "Oat milk"]
        XCTAssertEqual(
            ItemInput.suggestions(for: "milk", from: names),
            ["Milkshake mix", "Almond milk", "Buttermilk", "Oat milk"])
        XCTAssertEqual(ItemInput.suggestions(for: "MIL", from: names).first, "Milk")
        XCTAssertTrue(ItemInput.suggestions(for: "", from: names).isEmpty)
        XCTAssertTrue(ItemInput.suggestions(for: "zzz", from: names).isEmpty)
        XCTAssertEqual(ItemInput.suggestions(for: "m", from: names, limit: 2).count, 2)
    }

    // MARK: Lists

    func testGroupsSeparateOwnedFromShared() {
        let lists = [
            ListSummary(id: 1, name: "Mine", color: "ff9900", owner: "lori", role: .owner),
            ListSummary(id: 2, name: "Theirs", color: "3366cc", owner: "amy", role: .edit),
            ListSummary(id: 3, name: "Read only", color: "00aa00", owner: "bob", role: .view)
        ]
        let groups = ListGroups(lists)
        XCTAssertEqual(groups.mine.map(\.id), [1])
        XCTAssertEqual(groups.shared.map(\.id), [2, 3])
    }

    // MARK: Validation

    func testUsernameRules() {
        XCTAssertTrue(Validation.isValidUsername("lori"))
        XCTAssertTrue(Validation.isValidUsername("lori.h_2+x@home-1"))
        XCTAssertFalse(Validation.isValidUsername(""))
        XCTAssertFalse(Validation.isValidUsername("has space"))
        XCTAssertFalse(Validation.isValidUsername("bad!"))
        XCTAssertFalse(Validation.isValidUsername("lörí"))
        XCTAssertFalse(Validation.isValidUsername(String(repeating: "a", count: 51)))
        XCTAssertTrue(Validation.isValidUsername(String(repeating: "a", count: 50)))
    }

    func testEmailShape() {
        XCTAssertTrue(Validation.isValidEmail("lori@example.com"))
        XCTAssertFalse(Validation.isValidEmail("lori"))
        XCTAssertFalse(Validation.isValidEmail("lori@example"))
        XCTAssertFalse(Validation.isValidEmail("@example.com"))
        XCTAssertFalse(Validation.isValidEmail("lori@@example.com"))
        XCTAssertFalse(Validation.isValidEmail("lo ri@example.com"))
    }

    // MARK: Errors

    func testWaitTextIsHumanReadable() {
        XCTAssertEqual(APIError.waitText(1), "1 second")
        XCTAssertEqual(APIError.waitText(45), "45 seconds")
        XCTAssertEqual(APIError.waitText(60), "1 minute")
        XCTAssertEqual(APIError.waitText(900), "15 minutes")
        XCTAssertEqual(APIError.waitText(3600), "1 hour")
        XCTAssertEqual(APIError.waitText(7200), "2 hours")
    }

    func testFriendlyMessages() {
        XCTAssertTrue(APIError.network.errorDescription?.contains("connection") == true)
        XCTAssertEqual(
            APIError(code: .wrongPassword, status: 400, message: "Your current password was not correct.").errorDescription,
            "Your current password was not correct.")
        XCTAssertFalse(APIError(code: .serverError, status: 500, message: "SQL exploded").errorDescription?.contains("SQL") == true,
                       "server error details are for the log, not the person")
    }
}
