import XCTest
@testable import MySHSMU

/// Every outgoing request passes through the guard, so the interesting cases
/// are both "does it block the wrong thing" and "does it still allow the
/// endpoints the app actually uses".
final class URLGuardTests: XCTestCase {

    func testRejectsNonHTTPSchemes() {
        XCTAssertThrowsError(try URLGuard.validate(URL(string: "file:///etc/passwd")!))
        XCTAssertThrowsError(try URLGuard.validate(URL(string: "ftp://example.com/x")!))
    }

    func testRejectsLoopbackByName() {
        for host in ["localhost", "app.localhost", "printer.local", "svc.internal"] {
            XCTAssertThrowsError(
                try URLGuard.validate(URL(string: "http://\(host)/x")!),
                "expected \(host) to be blocked"
            )
        }
    }

    func testRejectsPrivateAndReservedIPv4Literals() {
        let blocked = [
            "127.0.0.1",       // loopback
            "127.1.2.3",       // loopback
            "0.0.0.0",         // unspecified
            "10.1.2.3",        // private
            "172.16.5.4",      // private
            "172.31.255.254",  // private
            "192.168.0.1",     // private
            "169.254.169.254", // link-local (cloud metadata)
            "100.64.0.1",      // carrier-grade NAT
            "224.0.0.1",       // multicast
            "255.255.255.255", // broadcast
            "198.51.100.7",    // TEST-NET-2
        ]
        for host in blocked {
            XCTAssertThrowsError(
                try URLGuard.validate(URL(string: "http://\(host)/x")!),
                "expected \(host) to be blocked"
            )
        }
    }

    func testRejectsNonRoutableIPv6Literals() {
        for host in ["[::1]", "[::]", "[fe80::1]", "[fc00::1]", "[fd12:3456::1]", "[ff02::1]"] {
            XCTAssertThrowsError(
                try URLGuard.validate(URL(string: "http://\(host)/x")!),
                "expected \(host) to be blocked"
            )
        }
    }

    func testAllowsPublicAddresses() {
        for host in ["8.8.8.8", "1.1.1.1", "203.0.114.10", "[2606:4700::1111]"] {
            XCTAssertNoThrow(
                try URLGuard.validate(URL(string: "https://\(host)/x")!),
                "expected \(host) to be allowed"
            )
        }
    }

    func testAllowsTheEndpointsTheAppActuallyCalls() {
        XCTAssertNoThrow(try URLGuard.validate(AppConfig.loginURL))
        XCTAssertNoThrow(try URLGuard.validate(AppConfig.updateJSONURL))
        XCTAssertNoThrow(try URLGuard.validate(
            URL(string: "https://webvpn2.shsmu.edu.cn/https/TOKEN/Home/GetCurriculumTable?vpn-12-o2-host")!
        ))
    }

    func testRejectsAnAddressWithNoHost() {
        XCTAssertThrowsError(try URLGuard.validate(URL(string: "https:///path")!))
    }

    func testValidatedReturnsTheURLWhenItPasses() throws {
        let url = URL(string: "https://8.8.8.8/x")!
        XCTAssertEqual(try URLGuard.validated(url), url)
    }
}

/// Timetable slot maths, shared by the curriculum grid and the classroom
/// timeline.
final class SlotResolverTests: XCTestCase {

    func testMapsPeriodStartTimesToSlots() {
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 8 * 60), 0)
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 8 * 60 + 50), 1)
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 9 * 60 + 40), 2)
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 12 * 60), 5)
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 13 * 60 + 30), 6)
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 20 * 60 + 10), 14)
    }

    func testFallsBackToTheSameHourWhenOffGrid() {
        // A lesson at 8:41 matches no window; the same-hour fallback keeps it
        // visible rather than dropping it from the grid.
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 8 * 60 + 41), 0)
    }

    func testFallsBackToTheFirstSlotWhenNothingMatches() {
        // 21:00 is past the last period; the Kotlin code defaults to slot 0.
        XCTAssertEqual(SlotResolver.startSlot(forMinutes: 21 * 60), 0)
    }

    func testSpansASinglePeriod() {
        XCTAssertEqual(
            SlotResolver.slotCount(startSlot: 0, beginMinutes: 8 * 60, endMinutes: 8 * 60 + 40),
            1
        )
    }

    func testSpansConsecutivePeriods() {
        // 08:00–09:30 covers the first two periods.
        XCTAssertEqual(
            SlotResolver.slotCount(startSlot: 0, beginMinutes: 8 * 60, endMinutes: 9 * 60 + 30),
            2
        )
    }

    func testFallsBackToADurationEstimateWhenTheEndIsOffGrid() {
        // 100 minutes is two 50-minute rows.
        XCTAssertEqual(
            SlotResolver.slotCount(startSlot: 0, beginMinutes: 8 * 60, endMinutes: 8 * 60 + 100),
            2
        )
    }

    func testNeverSpansPastTheEndOfTheGrid() {
        let lastSlot = standardTimeSlots.count - 1
        XCTAssertEqual(
            SlotResolver.slotCount(startSlot: lastSlot, beginMinutes: 20 * 60 + 10, endMinutes: 23 * 60),
            1
        )
    }
}
