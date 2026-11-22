//
//  DecodeFastPathTests.swift
//
//  The single-value decoder reads String, Int64, Int, Bool, Double and their optionals (and
//  Date?) by comparing types instead of casting to protocols. These round-trip every one, set
//  and null, and check that a read instance's change tracking is as before.
//

import Foundation
import Testing
@testable import Blackbird

struct FastPathModel: BlackbirdModel {
    @BlackbirdColumn var id: Int64
    @BlackbirdColumn var text: String
    @BlackbirdColumn var textOrNil: String?
    @BlackbirdColumn var big: Int64
    @BlackbirdColumn var bigOrNil: Int64?
    @BlackbirdColumn var number: Int
    @BlackbirdColumn var numberOrNil: Int?
    @BlackbirdColumn var flag: Bool
    @BlackbirdColumn var flagOrNil: Bool?
    @BlackbirdColumn var ratio: Double
    @BlackbirdColumn var ratioOrNil: Double?
    @BlackbirdColumn var when: Date
    @BlackbirdColumn var whenOrNil: Date?
}

struct DecodeFastPathTests {
    static func withDatabase(_ body: (Blackbird.Database) async throws -> Void) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fastpath\(UInt32.random(in: 0...UInt32.max)).sqlite").path
        defer { for file in Blackbird.Database.allFilePaths(for: path) { try? FileManager.default.removeItem(atPath: file) } }
        let db = try Blackbird.Database(path: path)
        try await body(db)
        await db.close()
    }

    @Test func everyCommonTypeRoundTripsSetAndNull() async throws {
        try await Self.withDatabase { db in
            let when = Date(timeIntervalSince1970: 1_790_000_000.25)
            let set = FastPathModel(id: 1, text: "text", textOrNil: "", big: Int64.min, bigOrNil: 0, number: -7, numberOrNil: Int.max, flag: true, flagOrNil: false,
                                    ratio: -0.5, ratioOrNil: Double.pi, when: when, whenOrNil: when)
            let null = FastPathModel(id: 2, text: "", textOrNil: nil, big: 0, bigOrNil: nil, number: 0, numberOrNil: nil, flag: false, flagOrNil: nil,
                                     ratio: 0, ratioOrNil: nil, when: Date(timeIntervalSince1970: 0), whenOrNil: nil)
            try await set.write(to: db)
            try await null.write(to: db)
            #expect(try await FastPathModel.read(from: db, id: 1) == set)
            #expect(try await FastPathModel.read(from: db, id: 2) == null)
        }
    }

    @Test func aReadInstanceTracksChangesAsBefore() async throws {
        try await Self.withDatabase { db in
            try await FastPathModel(id: 1, text: "a", textOrNil: nil, big: 1, bigOrNil: nil, number: 1, numberOrNil: nil, flag: false, flagOrNil: nil,
                                    ratio: 1, ratioOrNil: nil, when: Date(), whenOrNil: nil).write(to: db)
            var read = try #require(try await FastPathModel.read(from: db, id: 1))
            #expect(read.changedColumns(in: db).isEmpty)

            let sibling = read
            read.textOrNil = "b"
            #expect(read.changedColumns(in: db) == Blackbird.ColumnNames(["textOrNil"]))
            try await read.write(to: db)
            #expect(read.changedColumns(in: db).isEmpty)
            // The sibling copy shares the saved state but still holds the old value.
            #expect(sibling.changedColumns(in: db) == Blackbird.ColumnNames(["textOrNil"]))

            // Another database has never seen these values.
            try await Self.withDatabase { other in
                #expect(read.changedColumns(in: other).count == 13)
            }
        }
    }
}
