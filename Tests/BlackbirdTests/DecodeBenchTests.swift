//
//  DecodeBenchTests.swift
//
//  How much decoding rows into models costs, one read at a time and 10 at once. Off unless asked:
//
//    BLACKBIRD_BENCH=1 swift test -c release --filter DecodeBench
//
//  Prints wall and CPU time (getrusage) for 10 reads of 4,500 rows, one after another and then
//  all at once, as models and as raw rows.
//

import Foundation
import Testing
@testable import Blackbird

struct BenchShift: BlackbirdModel {
    @BlackbirdColumn var id: Int64
    @BlackbirdColumn var personID: Int64
    @BlackbirdColumn var day: String
    @BlackbirdColumn var startAt: Date
    @BlackbirdColumn var endAt: Date?
    @BlackbirdColumn var punchedInAt: Date?
    @BlackbirdColumn var punchedOutAt: Date?
    @BlackbirdColumn var source: String
    @BlackbirdColumn var note: String?
    @BlackbirdColumn var enteredAt: Date
    @BlackbirdColumn var enteredByUserID: Int64
    @BlackbirdColumn var approvedAt: Date?
    @BlackbirdColumn var approvedByUserID: Int64?
    @BlackbirdColumn var archivedAt: Date?
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["BLACKBIRD_BENCH"] != nil), .serialized)
struct DecodeBenchTests {
    static let rows = 4_500, runs = 10

    static func cpuSeconds() -> Double {
        var usage = rusage()
        #if os(Linux)
        getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)   // Glibc's RUSAGE_SELF is an enum
        #else
        getrusage(RUSAGE_SELF, &usage)
        #endif
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func measure(_ name: String, _ work: @escaping @Sendable () async throws -> Int) async throws {
        _ = try await work()
        var results = [String]()
        for concurrent in [false, true] {
            let cpu = cpuSeconds(), wall = Date()
            if concurrent {
                _ = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<runs { group.addTask { try await work() } }
                    return try await group.reduce(0, +)
                }
            } else {
                for _ in 0..<runs { _ = try await work() }
            }
            let used = cpuSeconds() - cpu, elapsed = Date().timeIntervalSince(wall)
            results.append(String(format: "%@: wall %.0f ms, CPU %.0f ms", concurrent ? "10 at once" : "one by one", elapsed * 1000, used * 1000))
        }
        print("BENCH \(name.padding(toLength: 12, withPad: " ", startingAt: 0)) \(results.joined(separator: "  |  "))")
    }

    @Test func decodingCost() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("bench\(UInt32.random(in: 0...UInt32.max)).sqlite").path
        defer { for file in Blackbird.Database.allFilePaths(for: path) { try? FileManager.default.removeItem(atPath: file) } }
        let db = try Blackbird.Database(path: path)
        let now = Date()
        try await db.transaction { core in
            for n in 0..<Self.rows {
                let start = now.addingTimeInterval(TimeInterval(n * 60))
                try BenchShift(id: Int64(n + 1), personID: Int64(n % 300), day: "2026-11-\(10 + n % 15)", startAt: start, endAt: start.addingTimeInterval(28_800),
                               punchedInAt: start, punchedOutAt: start.addingTimeInterval(28_800), source: "clock", note: n % 10 == 0 ? "late bus" : nil,
                               enteredAt: start, enteredByUserID: 1, approvedAt: nil, approvedByUserID: nil, archivedAt: nil).write(to: core)
            }
        }
        if ProcessInfo.processInfo.environment["BLACKBIRD_BENCH"] == "profile" {   // 10 at once for 8 s, for `sample`
            let until = Date().addingTimeInterval(8)
            while Date() < until {
                _ = try await withThrowingTaskGroup(of: Int.self) { group in
                    for _ in 0..<Self.runs { group.addTask { try await BenchShift.read(from: db, sqlWhere: "1 ORDER BY startAt").count } }
                    return try await group.reduce(0, +)
                }
            }
            await db.close()
            return
        }
        try await Self.measure("models") { try await BenchShift.read(from: db, sqlWhere: "1 ORDER BY startAt").count }
        try await Self.measure("raw rows") { try await db.query("SELECT * FROM BenchShift ORDER BY startAt").count }
        await db.close()
    }
}
