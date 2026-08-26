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
