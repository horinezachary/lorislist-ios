import XCTest
@testable import LorisListKit

final class AppLinkTests: XCTestCase {
    private let hosts: Set<String> = ["lorislist.horinetech.com"]
    private let key = "afb7e71ba6179c2a785abd25d648ab6a"

    private func parse(_ text: String) -> AppLink? {
        guard let url = URL(string: text) else { return nil }
        return AppLink.parse(url, siteHosts: hosts)
    }

    func testInvitationLink() {
        XCTAssertEqual(parse("https://lorislist.horinetech.com/share/\(key)"), .invitation(key: key))
    }

    func testPasswordResetLink() {
        XCTAssertEqual(parse("https://lorislist.horinetech.com/passwordReset/\(key)"), .passwordReset(token: key))
    }

    func testTrailingSlashQueryAndFragmentAreIgnored() {
        XCTAssertEqual(parse("https://lorislist.horinetech.com/share/\(key)/"), .invitation(key: key))
        XCTAssertEqual(parse("https://lorislist.horinetech.com/share/\(key)?utm=mail#top"), .invitation(key: key))
    }

    func testHostIsMatchedWithoutRegardToCase() {
        XCTAssertEqual(parse("https://LorisList.HorineTech.com/share/\(key)"), .invitation(key: key))
    }

    func testOtherSitesAreNotOurs() {
        XCTAssertNil(parse("https://evil.example/share/\(key)"))
        XCTAssertNil(parse("https://lorislist.horinetech.com.evil.example/share/\(key)"))
        XCTAssertNil(parse("https://evil.example/lorislist.horinetech.com/share/\(key)"))
    }

    func testOnlyHTTPSIsAccepted() {
        XCTAssertNil(parse("http://lorislist.horinetech.com/share/\(key)"))
        XCTAssertNil(parse("lorislist://lorislist.horinetech.com/share/\(key)"))
    }

    func testOtherPagesAndOddShapesAreIgnored() {
        XCTAssertNil(parse("https://lorislist.horinetech.com/"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/home"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/l/12"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/share"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/share/"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/share/\(key)/extra"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/passwordreset/\(key)"), "the path is case-sensitive on the server")
    }

    func testKeysThatCouldNotComeFromTheServerAreRejected() {
        XCTAssertNil(parse("https://lorislist.horinetech.com/share/short"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/share/\(String(repeating: "a", count: 200))"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/share/abc%2F..%2Fme%2F123456"))
        XCTAssertNil(parse("https://lorislist.horinetech.com/share/abcdefgh.ijklmnop"))
    }

    func testHostsComeFromTheAPIAddress() {
        let base = URL(string: "https://lorislist.horinetech.com/api/v1")!
        XCTAssertEqual(AppLink.siteHosts(forAPI: base), ["lorislist.horinetech.com"])
    }
}
