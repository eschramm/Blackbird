import XCTest
import SwiftUI
@testable import Blackbird

final class EntryDefaultTest: XCTestCase, @unchecked Sendable {

    // The @Entry default expression is evaluated on every read of an uninjected value, so the
    // fallback must be a single shared instance — otherwise each access hands back a different
    // empty database and a view can't even read back what it just wrote.
    func testUninjectedFallbackIsOneSharedInstance() {
        var ev = EnvironmentValues()
        XCTAssertTrue(ev.blackbirdDatabase === ev.blackbirdDatabase)
        XCTAssertTrue(ev.blackbirdDatabase === Blackbird.Database.unconfigured)
    }

    // Injection must bypass the fallback entirely, in either order.
    func testInjectedDatabaseWins() throws {
        let real = try Blackbird.Database.inMemoryDatabase()

        var ev = EnvironmentValues()
        _ = ev.blackbirdDatabase          // force the default first
        ev.blackbirdDatabase = real
        XCTAssertTrue(ev.blackbirdDatabase === real)

        var ev2 = EnvironmentValues()
        ev2.blackbirdDatabase = real      // inject before any read
        XCTAssertTrue(ev2.blackbirdDatabase === real)
        XCTAssertFalse(ev2.blackbirdDatabase === Blackbird.Database.unconfigured)
    }
}
