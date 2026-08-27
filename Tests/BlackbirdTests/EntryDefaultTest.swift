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

    // MARK: - Deferred "unconfigured" warning

    /// Points the warning at a capturing closure with a short delay, and restores the defaults
    /// afterwards so one test's state can't leak into another's.
    private func withWarningCaptured(
        _ body: (_ warnings: Blackbird.Locked<[String]>) async throws -> Void
    ) async rethrows {
        let warnings = Blackbird.Locked<[String]>([])
        Blackbird.Database.unconfiguredWarning.withLock { state in
            state = .init(
                hasWarned: false,
                checkScheduled: false,
                delayNanoseconds: 20_000_000,
                emit: { message in warnings.withLock { $0.append(message) } }
            )
        }
        defer { Blackbird.Database.unconfiguredWarning.withLock { $0 = .init() } }
        try await body(warnings)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    // SwiftUI can run a @BlackbirdLive… wrapper's update() before an ancestor's
    // .environment(\.blackbirdDatabase, …) has been applied. That transient bind is harmless — the
    // wrapper rebinds on the next update — so it must not produce a scary console warning.
    func testTransientUnconfiguredBindDoesNotWarn() async throws {
        let real = try Blackbird.Database.inMemoryDatabase()
        try await withWarningCaptured { warnings in
            let bound = Blackbird.Locked<Blackbird.Database?>(.unconfigured)
            Blackbird.Database.scheduleUnconfiguredWarningIfNeeded(boundTo: .unconfigured) {
                bound.value
            }
            bound.value = real            // injection arrives before the check runs
            try await settle()
            XCTAssertEqual(warnings.value.count, 0)
        }
    }

    // A query that is still reading from the throwaway database once things have settled is the
    // real misconfiguration, and is what the warning exists for.
    func testPersistentUnconfiguredBindWarnsOnce() async throws {
        try await withWarningCaptured { warnings in
            let bound = Blackbird.Locked<Blackbird.Database?>(.unconfigured)
            for _ in 0..<3 {
                Blackbird.Database.scheduleUnconfiguredWarningIfNeeded(boundTo: .unconfigured) {
                    bound.value
                }
            }
            try await settle()
            XCTAssertEqual(warnings.value.count, 1)
            XCTAssertTrue(warnings.value.first?.contains("throwaway in-memory database") ?? false)

            // Every later bind stays quiet: one warning per process is the whole point.
            Blackbird.Database.scheduleUnconfiguredWarningIfNeeded(boundTo: .unconfigured) {
                bound.value
            }
            try await settle()
            XCTAssertEqual(warnings.value.count, 1)
        }
    }

    // Binding a real database is not interesting and must never schedule anything.
    func testConfiguredBindNeverWarns() async throws {
        let real = try Blackbird.Database.inMemoryDatabase()
        try await withWarningCaptured { warnings in
            Blackbird.Database.scheduleUnconfiguredWarningIfNeeded(boundTo: real) { real }
            try await settle()
            XCTAssertEqual(warnings.value.count, 0)
        }
    }
}
