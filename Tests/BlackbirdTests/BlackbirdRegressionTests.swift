//
//           /\
//          |  |                       Blackbird
//          |  |
//         .|  |.       https://github.com/marcoarment/Blackbird
//         $    $
//        /$    $\          Copyright 2022–2023 Marco Arment
//       / $|  |$ \          Released under the MIT License
//      .__$|  |$__.
//           \/
//
//  BlackbirdRegressionTests.swift
//
//  Regression tests for specific bugs. Currently: transaction/savepoint integrity.
//

import XCTest
@testable import Blackbird

final class BlackbirdRegressionTests: XCTestCase, @unchecked Sendable {
    enum Error: Swift.Error {
        case testError
    }

    var sqliteFilename = ""

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.path
        sqliteFilename = "\(dir)/test\(Int64.random(in: 0..<Int64.max)).sqlite"
    }

    override func tearDownWithError() throws {
        if sqliteFilename != "", sqliteFilename != ":memory:", FileManager.default.fileExists(atPath: sqliteFilename) {
            for path in Blackbird.Database.allFilePaths(for: sqliteFilename) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: Transactions and savepoints

    // A rolled-back transaction must not leave the connection inside an open
    // transaction: all writes after it must survive close and reopen.
    func testWritesPersistAfterRolledBackTransaction() async throws {
        var db = try Blackbird.Database(path: sqliteFilename)

        let result = try await db.cancellableTransaction { core in
            try TestModel(id: 1, title: "rolled back", url: TestData.randomURL).write(to: core)
            throw Blackbird.Error.cancelTransaction
        }
        guard case .rolledBack = result else { return XCTFail("expected rollback") }

        try await db.transaction { core in
            try TestModel(id: 2, title: "committed transaction", url: TestData.randomURL).write(to: core)
        }
        try await TestModel(id: 3, title: "plain write", url: TestData.randomURL).write(to: db)

        await db.close()
        db = try Blackbird.Database(path: sqliteFilename)

        let all = try await TestModel.read(from: db, matching: .all)
        XCTAssertEqual(Set(all.map(\.id)), [2, 3])
        await db.close()
    }

    // Same, but for a transaction that fails with an arbitrary thrown error.
    func testWritesPersistAfterFailedTransaction() async throws {
        var db = try Blackbird.Database(path: sqliteFilename)

        do {
            try await db.transaction { core in
                try TestModel(id: 1, title: "failed", url: TestData.randomURL).write(to: core)
                throw Error.testError
            }
            XCTFail("expected throw")
        } catch Error.testError { } // expected

        try await TestModel(id: 2, title: "after failure", url: TestData.randomURL).write(to: db)

        await db.close()
        db = try Blackbird.Database(path: sqliteFilename)

        let all = try await TestModel.read(from: db, matching: .all)
        XCTAssertEqual(all.map(\.id), [2])
        await db.close()
    }

    // MARK: Schema resolution

    // Schema resolution may CREATE or ALTER the table. If it ran inside a transaction that
    // then rolled back, the table is gone but must not still be cached as resolved.
    func testSchemaResolutionSurvivesRolledBackTransaction() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        let result = try await db.cancellableTransaction { core in
            try TestModel(id: 1, title: "first touch", url: TestData.randomURL).write(to: core)
            throw Blackbird.Error.cancelTransaction
        }
        guard case .rolledBack = result else { return XCTFail("expected rollback") }

        try await TestModel(id: 2, title: "after rollback", url: TestData.randomURL).write(to: db)
        let all = try await TestModel.read(from: db, matching: .all)
        XCTAssertEqual(all.map(\.id), [2])
        await db.close()
    }

    // MARK: Changed-column tracking

    // A copy's write must persist its own changes even if the original
    // instance was written (clearing the shared flags) in between.
    func testSiblingCopyWritePersists() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        try await TestModel(id: 1, title: "Original", url: TestData.randomURL).write(to: db)
        let a = try await TestModel.read(from: db, id: 1)!
        var b = a
        b.title = "Updated by copy"

        try await a.write(to: db) // clears the flags shared with b
        try await b.write(to: db) // must still persist b's title

        let final = try await TestModel.read(from: db, id: 1)
        XCTAssertEqual(final?.title, "Updated by copy")
        await db.close()
    }

    // Same scenario through the instance cache, which hands out shared copies aggressively.
    func testSiblingCopyWritePersistsWithCache() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        try await TestModelWithCache(id: 1, title: "Original", url: TestData.randomURL).write(to: db)
        let a = try await TestModelWithCache.read(from: db, id: 1)!
        var b = try await TestModelWithCache.read(from: db, id: 1)!
        b.title = "Updated by copy"

        try await a.write(to: db)
        try await b.write(to: db)

        let final = try await TestModelWithCache.read(from: db, id: 1)
        XCTAssertEqual(final?.title, "Updated by copy")
        await db.close()
    }

    // MARK: Cache coherence

    // A rolled-back transaction must not leave its uncommitted values readable from the cache.
    func testRolledBackTransactionInvalidatesCache() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        try await TestModelWithCache(id: 1, title: "Original", url: TestData.randomURL).write(to: db)
        let before = try await TestModelWithCache.read(from: db, id: 1)
        XCTAssertEqual(before?.title, "Original")

        let result = try await db.cancellableTransaction { core in
            var t = try TestModelWithCache.read(from: core, id: 1)!
            t.title = "Uncommitted"
            try t.write(to: core)
            throw Blackbird.Error.cancelTransaction
        }
        guard case .rolledBack = result else { return XCTFail("expected rollback") }

        let after = try await TestModelWithCache.read(from: db, id: 1)
        XCTAssertEqual(after?.title, "Original")
        await db.close()
    }

    // An open transaction's writes must not be published through the cache, which readers on
    // other threads consult without waiting for the database actor.
    func testUncommittedWritesAreNotVisibleInCache() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        try await TestModelWithCache(id: 1, title: "Original", url: TestData.randomURL).write(to: db)
        _ = try await TestModelWithCache.read(from: db, id: 1) // warm the cache

        let result = try await db.cancellableTransaction { core in
            var t = try TestModelWithCache.read(from: core, id: 1)!
            t.title = "Uncommitted"
            try t.write(to: core)

            let cached = db.cache.readModel(tableName: TestModelWithCache.tableName, primaryKey: .integer(1)) as? TestModelWithCache
            XCTAssertNotEqual(cached?.title, "Uncommitted", "cache published an uncommitted row")

            // The transaction must still see its own write.
            XCTAssertEqual(try TestModelWithCache.read(from: core, id: 1)?.title, "Uncommitted")
            throw Blackbird.Error.cancelTransaction
        }
        guard case .rolledBack = result else { return XCTFail("expected rollback") }

        let after = try await TestModelWithCache.read(from: db, id: 1)
        XCTAssertEqual(after?.title, "Original")
        await db.close()
    }

    // The flip side: once the transaction commits, its buffered entries must actually reach the
    // cache, or deferring population would just be a slower way of disabling it.
    func testCommittedTransactionPopulatesCache() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        try await db.transaction { core in
            for i in 1...20 {
                try TestModelWithCache(id: Int64(i), title: "t\(i)", url: TestData.randomURL).write(to: core)
            }
        }

        // Reads inside a transaction must be served from the cache, not re-fetched every time.
        _ = try await db.transaction { core in try TestModelWithCache.read(from: core, id: 5) }
        db.resetCachePerformanceMetrics(tableName: TestModelWithCache.tableName)
        for _ in 0..<5 {
            _ = try await db.transaction { core in try TestModelWithCache.read(from: core, id: 5) }
        }

        let metrics = db.cachePerformanceMetricsByTableName()[TestModelWithCache.tableName]
        XCTAssertEqual(metrics?.hits, 5)
        XCTAssertEqual(metrics?.misses, 0)
        await db.close()
    }

    // MARK: Value conversion safety

    // A malformed or truncated SQLite literal must return nil, not crash. A bare quote satisfies
    // both the prefix and suffix checks, and an odd-length hex body indexes past its end.
    func testMalformedSQLiteLiteralsDoNotCrash() {
        XCTAssertNil(Blackbird.Value.fromSQLiteLiteral("'"))
        XCTAssertNil(Blackbird.Value.fromSQLiteLiteral("X'"))
        XCTAssertNil(Blackbird.Value.fromSQLiteLiteral("X'A'"))
        XCTAssertEqual(Blackbird.Value.fromSQLiteLiteral("''"), .text(""))
        XCTAssertEqual(Blackbird.Value.fromSQLiteLiteral("NULL"), .null)
    }

    // Int(d) traps on NaN, infinity, and doubles beyond Int's range.
    func testOutOfRangeDoubleConversionsReturnNil() {
        XCTAssertNil(Blackbird.Value.double(.nan).intValue)
        XCTAssertNil(Blackbird.Value.double(.infinity).intValue)
        XCTAssertNil(Blackbird.Value.double(1e300).intValue)
        XCTAssertNil(Blackbird.Value.double(.nan).int64Value)
        XCTAssertNil(Blackbird.Value.double(-.infinity).int64Value)
        XCTAssertEqual(Blackbird.Value.double(3.7).intValue, 3)
        XCTAssertEqual(Blackbird.Value.double(-3.7).intValue, -3)
    }

    // Any nonzero integer is true, including negatives.
    func testNegativeIntegersAreTrue() {
        XCTAssertEqual(Blackbird.Value.integer(-1).boolValue, true)
        XCTAssertEqual(Blackbird.Value.integer(1).boolValue, true)
        XCTAssertEqual(Blackbird.Value.integer(0).boolValue, false)
        XCTAssertEqual(Blackbird.Value.double(-1).boolValue, true)
    }

    // A -1 (C-string) bind length truncates at the first interior NUL.
    func testStringWithInteriorNulRoundTrips() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)
        let title = "before\u{0}after"
        try await TestModel(id: 1, title: title, url: TestData.randomURL).write(to: db)
        let back = try await TestModel.read(from: db, id: 1)
        XCTAssertEqual(back?.title, title)
        await db.close()
    }

    // MARK: Codable blob columns

    // A Codable type stored as a BLOB must round-trip through its own unifiedRepresentation()
    // and from(unifiedRepresentation:), whether or not that representation happens to be JSON.
    func testStorableAsDataRoundTripsBothRepresentations() async throws {
        let db = try Blackbird.Database(path: sqliteFilename)

        let prefs = RegressionPrefs(theme: "dark", fontSize: 14)
        let ref = UUID()
        try await RegressionBlobModel(id: 1, prefs: prefs, ref: ref).write(to: db)

        let back = try await RegressionBlobModel.read(from: db, id: 1)
        XCTAssertEqual(back?.prefs, prefs, "JSON-backed blob column did not round-trip")
        XCTAssertEqual(back?.ref, ref, "raw-bytes blob column (UUID) did not round-trip")
        await db.close()
    }
}

// A JSON-backed Codable blob column, the documented use of BlackbirdStorableAsData.
struct RegressionPrefs: Codable, Equatable, BlackbirdStorableAsData, BlackbirdColumnWrappable {
    var theme: String
    var fontSize: Int

    func unifiedRepresentation() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    static func from(unifiedRepresentation: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: unifiedRepresentation)) ?? Self(theme: "light", fontSize: 12)
    }
    static func fromValue(_ value: Blackbird.Value) -> Self? {
        value.dataValue.map { from(unifiedRepresentation: $0) }
    }
}

// Optional columns: a non-optional blob column can't decode the empty-blob column default.
struct RegressionBlobModel: BlackbirdModel {
    @BlackbirdColumn var id: Int
    @BlackbirdColumn var prefs: RegressionPrefs?
    @BlackbirdColumn var ref: UUID?
}

// MARK: Waiting for another connection's write lock

#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// A second, plain SQLite connection to the same file, standing in for another program (a
/// backup tool, a second process) that takes the write lock for a moment.
final class WriteLockHolder: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw BlackbirdRegressionTests.Error.testError
        }
    }

    /// Takes the write lock now and keeps it until ``release()``. For tests that expect a
    /// failure while it is held: nothing depends on how fast the machine is.
    func hold() throws {
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw BlackbirdRegressionTests.Error.testError
        }
    }

    func release() {
        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
    }

    /// Takes the write lock now and gives it back after `seconds`, from another thread. For
    /// tests that expect a wait to end in success.
    func hold(for seconds: TimeInterval) throws {
        try hold()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in release() }
    }

    deinit { sqlite3_close(handle) }
}

extension BlackbirdRegressionTests {

    private func isBusy(_ error: Swift.Error) -> Bool {
        String(describing: error).contains("SQLITE_BUSY")
    }

    /// Opens the test database with a busy timeout, and one committed row so the table exists.
    private func openWithBusyTimeout(_ milliseconds: Int, options: Blackbird.Database.Options = []) async throws -> Blackbird.Database {
        let db = try Blackbird.Database(path: sqliteFilename, options: options)
        try await db.query("PRAGMA busy_timeout = \(milliseconds)")
        if try await TestModel.read(from: db, id: 1) == nil {
            try await TestModel(id: 1, title: "first", url: TestData.randomURL).write(to: db)
        }
        return db
    }

    private func readThenWrite(id: Int64, in db: Blackbird.Database) async throws {
        try await db.transaction { core in
            _ = try TestModel.read(from: core, id: 1)
            try TestModel(id: id, title: "read then write", url: TestData.randomURL).write(to: core)
        }
    }

    private func idsAfterReopening(_ db: Blackbird.Database) async throws -> Set<Int64> {
        await db.close()
        let reopened = try Blackbird.Database(path: sqliteFilename)
        let ids = Set(try await TestModel.read(from: reopened, matching: .all).map(\.id))
        await reopened.close()
        return ids
    }

    // The hazard Options.immediateTransactions exists for. Without it, a transaction that reads
    // before it writes fails at once when another connection holds the write lock, however
    // long the busy timeout: SQLite will not make a connection holding a read lock wait.
    // If this test starts failing, SQLite or Blackbird changed and the option may be moot.
    func testWithoutImmediateTransactionsAReadThenWriteFailsAtOnceDespiteABusyTimeout() async throws {
        let db = try await openWithBusyTimeout(3000)
        let other = try WriteLockHolder(path: sqliteFilename)
        try other.hold()
        let started = Date()
        do {
            try await readThenWrite(id: 2, in: db)
            XCTFail("expected SQLITE_BUSY")
        } catch {
            XCTAssertTrue(isBusy(error), "\(error)")
        }
        // The lock is still held, so it did not get there by waiting: well under the 3 s timeout.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "it failed without waiting for the lock")
        other.release()

        // The failed transaction left the connection usable, and wrote nothing.
        try await TestModel(id: 3, title: "afterwards", url: TestData.randomURL).write(to: db)
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 3])
    }

    func testImmediateTransactionsWaitForAnotherConnectionsWriteLock() async throws {
        let db = try await openWithBusyTimeout(3000, options: [.immediateTransactions])
        let other = try WriteLockHolder(path: sqliteFilename)
        try other.hold(for: 0.3)
        let started = Date()
        try await readThenWrite(id: 2, in: db)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.2, "it waited for the lock")
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 2])
    }

    // For a database opened by code that does not pass options through.
    func testImmediateTransactionsCanBeTurnedOnAndOffAfterOpening() async throws {
        let db = try await openWithBusyTimeout(3000)
        await db.setImmediateTransactions(true)
        let other = try WriteLockHolder(path: sqliteFilename)
        try other.hold(for: 0.3)
        try await readThenWrite(id: 2, in: db)

        await db.setImmediateTransactions(false)
        try other.hold()
        do {
            try await readThenWrite(id: 3, in: db)
            XCTFail("expected SQLITE_BUSY")
        } catch {
            XCTAssertTrue(isBusy(error), "\(error)")
        }
        other.release()
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 2])
    }

    // The wait is bounded by the busy timeout. Giving up must leave no transaction open.
    func testImmediateTransactionThatTimesOutLeavesTheConnectionUsable() async throws {
        let db = try await openWithBusyTimeout(100, options: [.immediateTransactions])
        let other = try WriteLockHolder(path: sqliteFilename)
        try other.hold()
        do {
            try await readThenWrite(id: 2, in: db)
            XCTFail("expected SQLITE_BUSY")
        } catch {
            XCTAssertTrue(isBusy(error), "\(error)")
        }
        let depth = await db.core.transactionDepth
        XCTAssertEqual(depth, 0)
        other.release()

        try await readThenWrite(id: 3, in: db)
        try await TestModel(id: 4, title: "plain write", url: TestData.randomURL).write(to: db)
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 3, 4])
    }

    // Rolling back, by cancelling or by throwing, must end the BEGIN IMMEDIATE too: otherwise
    // every later write would sit in an open transaction and vanish at close.
    func testImmediateTransactionsRollBackCompletely() async throws {
        let db = try await openWithBusyTimeout(1000, options: [.immediateTransactions])

        let result = try await db.cancellableTransaction { core in
            try TestModel(id: 2, title: "cancelled", url: TestData.randomURL).write(to: core)
            throw Blackbird.Error.cancelTransaction
        }
        guard case .rolledBack = result else { return XCTFail("expected rollback") }

        do {
            try await db.transaction { core in
                try TestModel(id: 3, title: "failed", url: TestData.randomURL).write(to: core)
                throw Error.testError
            }
            XCTFail("expected throw")
        } catch Error.testError { } // expected

        // Another connection can take the write lock, so this one is not still holding it.
        let other = try WriteLockHolder(path: sqliteFilename)
        try other.hold()
        other.release()

        try await readThenWrite(id: 4, in: db)
        try await TestModel(id: 5, title: "plain write", url: TestData.randomURL).write(to: db)
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 4, 5])
    }

    // Only the outermost transaction begins and commits; inner ones stay plain savepoints.
    func testImmediateTransactionsNest() async throws {
        let db = try await openWithBusyTimeout(1000, options: [.immediateTransactions])
        try await db.transaction { core in
            try TestModel(id: 2, title: "outer", url: TestData.randomURL).write(to: core)
            let inner = try core.cancellableTransaction { core in
                try TestModel(id: 3, title: "inner, cancelled", url: TestData.randomURL).write(to: core)
                throw Blackbird.Error.cancelTransaction
            }
            guard case .rolledBack = inner else { return XCTFail("expected inner rollback") }
            try core.transaction { core in
                try TestModel(id: 4, title: "inner, committed", url: TestData.randomURL).write(to: core)
            }
        }
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 2, 4])
    }

    // A transaction the caller began by hand is respected: no second BEGIN, and no COMMIT of
    // the caller's transaction on their behalf.
    func testImmediateTransactionsInsideACallersOwnTransaction() async throws {
        let db = try await openWithBusyTimeout(1000, options: [.immediateTransactions])
        try await db.execute("BEGIN")
        try await readThenWrite(id: 2, in: db)
        try await db.execute("ROLLBACK")
        try await readThenWrite(id: 3, in: db)
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 3])
    }

    // A smoke test only: SQLite accepts BEGIN IMMEDIATE on a read-only connection, so this
    // would pass even if the option were not ignored. It shows that reading still works.
    func testImmediateTransactionsDoNotBreakAReadOnlyDatabase() async throws {
        let writable = try await openWithBusyTimeout(1000)
        await writable.close()

        let db = try Blackbird.Database(path: sqliteFilename, options: [.readOnly, .immediateTransactions])
        await db.setImmediateTransactions(true)
        let title = try await db.transaction { core in
            try TestModel.read(from: core, id: 1)?.title
        }
        XCTAssertEqual(title, "first")
        await db.close()
    }

    // An async transaction's action can suspend, and other work can then run on the same
    // connection. It joins the open transaction, as it always has; it must not begin or
    // commit one of its own.
    func testWorkInterleavedWithASuspendedImmediateTransaction() async throws {
        let db = try await openWithBusyTimeout(1000, options: [.immediateTransactions])
        let result = try await db.cancellableTransaction { core in
            try TestModel(id: 2, title: "outer", url: TestData.randomURL).write(to: core)
            // Stands in for work arriving during a suspension: a nested transaction and a
            // plain write, both of which complete before the outer one is cancelled.
            try await Task.sleep(nanoseconds: 10_000_000)
            try core.transaction { core in
                try TestModel(id: 3, title: "nested", url: TestData.randomURL).write(to: core)
            }
            try core.execute("UPDATE TestModel SET title = 'changed' WHERE id = 1")
            throw Blackbird.Error.cancelTransaction
        }
        guard case .rolledBack = result else { return XCTFail("expected rollback") }

        // Nothing committed early: all of it went with the outer transaction.
        let first = try await TestModel.read(from: db, id: 1)
        XCTAssertEqual(first?.title, "first")
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1])
    }

    // close() can run while an async transaction's action is suspended. Unwinding the
    // transaction afterwards must not touch the closed connection.
    func testClosingDuringASuspendedImmediateTransaction() async throws {
        let db = try await openWithBusyTimeout(1000, options: [.immediateTransactions])
        do {
            try await db.transaction { core in
                try TestModel(id: 2, title: "never committed", url: TestData.randomURL).write(to: core)
                await db.close()
            }
            XCTFail("expected databaseIsClosed")
        } catch Blackbird.Database.Error.databaseIsClosed { } // expected

        let reopened = try Blackbird.Database(path: sqliteFilename)
        let ids = Set(try await TestModel.read(from: reopened, matching: .all).map(\.id))
        XCTAssertEqual(ids, [1])
        await reopened.close()
    }

    // COMMIT can fail after the savepoint was released: a deferred foreign key is only checked
    // at COMMIT. The transaction is then still open, with no savepoint left to roll back to,
    // and must be ended with a plain ROLLBACK.
    func testImmediateTransactionWhoseCommitFailsIsRolledBack() async throws {
        let db = try await openWithBusyTimeout(1000, options: [.immediateTransactions])
        try await db.execute("PRAGMA foreign_keys = ON")
        try await db.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        try await db.execute("CREATE TABLE child (id INTEGER PRIMARY KEY, parentID INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)")

        do {
            try await db.transaction { core in
                try TestModel(id: 2, title: "same transaction", url: TestData.randomURL).write(to: core)
                try core.execute("INSERT INTO child (id, parentID) VALUES (1, 99)")
            }
            XCTFail("expected the commit to fail")
        } catch {
            XCTAssertTrue(String(describing: error).contains("CONSTRAINT"), "\(error)")
        }
        let depth = await db.core.transactionDepth
        XCTAssertEqual(depth, 0)

        // Not left inside the failed transaction: this write is durable, and none of that one's are.
        try await TestModel(id: 3, title: "afterwards", url: TestData.randomURL).write(to: db)
        let children = try await db.query("SELECT COUNT(*) AS n FROM child").first?["n"]?.intValue
        XCTAssertEqual(children, 0)
        let ids = try await idsAfterReopening(db)
        XCTAssertEqual(ids, [1, 3])
    }

    func testImmediateTransactionsWorkInMemory() async throws {
        let db = try Blackbird.Database.inMemoryDatabase(options: [.immediateTransactions])
        try await db.transaction { core in
            try TestModel(id: 1, title: "one", url: TestData.randomURL).write(to: core)
            _ = try TestModel.read(from: core, id: 1)
            try TestModel(id: 2, title: "two", url: TestData.randomURL).write(to: core)
        }
        let count = try await TestModel.read(from: db, matching: .all).count
        XCTAssertEqual(count, 2)
        await db.close()
    }
}
