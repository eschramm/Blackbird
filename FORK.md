# Fork notes

This fork tracks [marcoarment/Blackbird](https://github.com/marcoarment/Blackbird).
Branches: `local` (ours, what apps consume via tags), `primary-fork-main` / `upstream/main`
(Marco's mainline), `upstream/fable` (Marco's unmerged working branch — **not** on `origin`,
despite what some commit messages say).

Last compared against `upstream/fable` @ `7eac04b` (2026-08).

## What we changed relative to upstream

### Transaction and cache correctness (ported from `upstream/fable`, 2026-08)

Five fixes, four identical to Marco's and one deliberately different. Found while diagnosing a
user losing the back nine of a round in StattyCaddy: an error alert mid-round left the connection
inside a permanently open transaction, and everything entered afterward was discarded when iOS
suspended the app.

| Fix | Where | vs. fable |
|---|---|---|
| `ROLLBACK TO SAVEPOINT` must be followed by `RELEASE`, or the connection stays inside an open transaction and every later write is lost on close | `BlackbirdDatabase.swift` | same |
| Schema resolution isn't marked resolved until the transaction commits (a rolled-back `CREATE`/`ALTER` would otherwise leave the table cached as resolved but absent) | `BlackbirdSchema.swift`, `BlackbirdDatabase.swift` | same, minus fable's nested-transaction machinery |
| A column's changed-flag is shared by every struct copy, so a sibling's write hid another copy's edit and wrote zero columns | `BlackbirdColumn.swift` | same, minus `markHasChanged()` (Skybridge-only) |
| `Semaphore.wait()` decrement and continuation-enqueue made atomic; a `signal()` in between lost the wakeup | `Blackbird.swift` | same |
| Cache population during transactions | `BlackbirdCache.swift` | **ours differs — see below** |

**The cache divergence.** Marco's fable branch *skips* cache population while a transaction is
open. That's correct but, for a caller that wraps everything in transactions (BBWrapper does —
every async read and write opens one), it disables the cache entirely: measured 0 hits / 10 misses
on a workload that previously ran 10 hits / 0 misses.

Ours *defers* instead: entries are buffered and applied when the outermost transaction commits,
dropped when it rolls back. A model write also evicts the live entry immediately, so reads inside
the transaction fall through to the database and see the transaction's own uncommitted writes
rather than a stale cached value. Same isolation guarantee, full cache performance.

Regression tests in `Tests/BlackbirdTests/BlackbirdRegressionTests.swift`. Two of them pin the
cache behavior precisely, and each rules out one of the alternatives:

- `testUncommittedWritesAreNotVisibleInCache` — fails on stock upstream (publishes uncommitted rows)
- `testCommittedTransactionPopulatesCache` — fails on fable's skip approach (cache never warms)

### Value-conversion and crash-safety fixes (ported from `upstream/fable`, 2026-08)

`Blackbird.swift` now matches `upstream/fable` exactly.

- `fromSQLiteLiteral` length guards — a bare `"'"` satisfied both the prefix and suffix checks and
  built a reversed string range; an odd-length hex blob literal indexed past its end. Both crashed.
- `intValue` / `int64Value` use `Int(exactly: d.rounded(.towardZero))`. `Int(d)` **traps** on NaN,
  infinity, and out-of-range doubles.
- `boolValue` treats any nonzero integer as true. It previously used `i > 0`, so a stored `-1`
  read as `false`.
- `sqlite3_bind_text` binds an explicit byte count instead of `-1`, which truncated strings at the
  first interior NUL.
- `Value.hash(into:)` discriminates per case instead of building a SQLite literal string on every
  hash. Cache keys are `[Blackbird.Value]`, so this sits on the cache hot path.

**Beyond fable:** the bind fix alone doesn't make interior NULs round-trip — the *read* path used
`String(cString:)`, which stops at the first NUL, so the string came back truncated even though
SQLite had stored all of it. `BlackbirdDatabase.swift` now reads text with an explicit
`sqlite3_column_bytes` length, mirroring how the BLOB case already worked. Covered by
`testStringWithInteriorNulRoundTrips`.

### Codable blob columns

`BlackbirdCodable.swift` decoded any `BlackbirdStorableAsData` type by running `JSONDecoder` over
the stored blob, ignoring the protocol's own `from(unifiedRepresentation:)` hook. That made the
protocol asymmetric — writes went through `unifiedRepresentation()`, reads through JSON — and
broke every conformer whose representation isn't JSON. `UUID` (ours, in `ESAdditions.swift`) stores
raw 16 bytes, so **UUID columns failed to read at all** with "The given data was not valid JSON."

Decoding now goes through `from(unifiedRepresentation:)`, which is symmetric with the write side
and works for both JSON-backed and raw-bytes types. `BlackbirdStorableAsData` carries documentation
and an example. Covered by `testStorableAsDataRoundTripsBothRepresentations`.

Two things to know when using it:

- **Declare blob columns optional** unless the type can decode from empty `Data`. Schema resolution
  validates a model by decoding the table's column defaults, and a `BLOB` column defaults to an
  empty blob — so a non-optional JSON-backed column trips a `fatalError` at first use.
- `from(unifiedRepresentation:)` can't throw, so return a fallback rather than force-unwrapping;
  stored blobs may predate a change to the type's shape.

### Longer-standing local additions

## What `upstream/fable` has that we haven't taken

### Features (deliberately skipped)

- **Skybridge** (`BlackbirdSkybridge.swift`, 673 lines) — CloudKit sync via `CKSyncEngine`.
  Skipped: record names are `tableName:primaryKey`, and our models mint integer ids with
  `MAX(id)+1`, so two offline devices generate colliding record names and last-write-wins
  silently destroys one. Adopting it means UUID or composite keys first. It also syncs each
  table independently with per-row conflict resolution, with nothing sequencing a child row
  after its parent.
- **Incremental FTS rebuilds** (`BlackbirdModelSearch.swift`, plus model API) — not needed; no
  full-text search in our apps.
- **Incremental vacuum API** (`BlackbirdVacuum.swift`).
- **Nested transactions and the async transaction barrier** — `transactionDepth` is ported (the
  schema fix needs it) but not `isNested`, `currentTransactionID`, or
  `Error.anotherTransactionInProgress`. Our callers only use the async `dbTransaction`, so
  nesting doesn't arise.
- ~3,300 lines of edge-case tests (concurrency / query / schema / value). Several depend on the
  nesting machinery above.

### Bug fixes still on the table

Worth revisiting; none are ported yet.

- Change reporting and observation: results invalidated by a change arriving mid-generation are
  no longer cached; accumulated column names are no longer discarded; trigger-written rows no
  longer force whole-table change reports.
- Index DDL now backtick-quotes table and column names; all-primary-key tables generate
  `ON CONFLICT DO NOTHING` instead of an empty clause (we don't currently have such a table).
- Structured-query expression compilation fixes.

### Intentionally not taking

- `Blackbird.Row.value(keyPath:)` — fable softened upstream's `fatalError` on a missing column to
  `return nil`, for Skybridge's row-to-instance path. We keep upstream's `fatalError`; without
  Skybridge, a missing column is a programming error worth crashing on.

## Merge guidance

`upstream/fable` is not merged into `upstream/main` and may be rebased or abandoned. If it does
land, expect conflicts in exactly the files above. In `BlackbirdCache.swift`, keep ours — the
buffered approach is a superset of Marco's guarantee. Everywhere else, prefer theirs.

`Tests/BlackbirdTests/BlackbirdRegressionTests.swift` shares a filename and class name with
fable's, so a merge conflicts there once; theirs is a superset except for the two cache tests
above, which must be kept.

## Verification

Blackbird's own suite: 40 tests, 0 failures. BBWrapper built against this working copy (via
`swift package edit blackbird --path …`) rather than its pinned tag: 36 tests, 0 failures across
`BBWrapperTests`, `BBFieldFormatTests`, and `BBSyncTests`.
