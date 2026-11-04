import XCTest
@testable import JARVIS

final class ShopAroundTests: XCTestCase {
    func testQuoteRequestsMatchAndChatDoesNot() {
        XCTAssertTrue(ShopAround.matches("get me quotes for a boiler"))
        XCTAssertTrue(ShopAround.matches("shop around for insurance"))
        XCTAssertTrue(ShopAround.matches("find me a plumber"))
        XCTAssertFalse(ShopAround.matches("hello there"))
        XCTAssertFalse(ShopAround.matches("approve"))
    }

    func testYesStartsAndApproveBooks() {
        XCTAssertTrue(ShopAround.confirms("YES"))
        XCTAssertTrue(ShopAround.confirms("go ahead"))
        XCTAssertFalse(ShopAround.confirms("approve"))
        XCTAssertTrue(ShopAround.approves("Approve."))
        XCTAssertFalse(ShopAround.approves("yes"))
    }

    func testPhonesStayCappedAndSkipEmergencies() {
        let phones = ShopAround.phones(in: "07700 900201, 07700 900202, 07700 900203, 07700 900204, 07700 900205, 07700 900206 and 999")
        XCTAssertEqual(phones.count, 5)
        XCTAssertEqual(phones.first, "07700 900201")
        XCTAssertFalse(phones.contains("999"))
    }
}
