import XCTest

/// Redman ledger "data loss" (verified 2026-09-28): an unreadable month aggregate must not read as an
/// EMPTY month.
///
/// THE DEFECT. `HistoryStore.readAggregate` answered "there is no month file" and "the month file will
/// not decode" with the same `[:]` (`try? … ?? [:]`). `aggregate(day:)` then merged ONE day into that
/// `[:]` and atomically wrote it over the month file — whose other days' raw files had already been
/// pruned, because the raw tier only keeps 7 days. Up to a month of hourly history (Day / Health tabs,
/// limit-hold hours) disappeared without a sound, and the next run pruned the incoming day's raw too
/// (the overwrite DID contain its hours), so not even the day being folded survived as raw.
///
/// The same landmine SWEEP H2 defused for `PauseCapture`: Swift's synthesized `Decodable` throws on a
/// missing key, so the day `HourlyAggregate` gains one non-optional field, EVERY month the previous
/// release wrote stops decoding — and, with the old read, every one of them would be overwritten by
/// the first maintenance run after the upgrade.
///
/// The tests here are real bytes in a real temp directory, driven through `runMaintenance()` — the one
/// production entry point — so the decode step that was the defect is actually exercised.
@MainActor
final class HistoryAggregateReadTests: XCTestCase {

    /// A `let` (XCTest makes a fresh instance per test, so a fresh directory per test): a Sendable
    /// constant is readable from the nonisolated `setUp` / `tearDown` without an isolation warning.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("histagg-\(UUID().uuidString)")
    final class Clock { var t: Int; init(_ t: Int) { self.t = t } }

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        // A test may have made a file unreadable; restore it so the directory can always be removed.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for n in names {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                       ofItemAtPath: dir.appendingPathComponent(n).path)
            }
        }
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// 2025-06-11 00:00 UTC (a multiple of 86400) — "today" in every test.
    let day0 = 1_749_600_000
    /// 2025-06-03: 8 days old, so maintenance folds it and then wants to prune its raw file.
    var old: Int { day0 - 8 * 86400 }
    /// 2025-06-02: an EARLIER day of the same month, whose raw file is long gone — its hours exist
    /// only in the month aggregate. This is what the defect destroyed.
    var earlier: Int { day0 - 9 * 86400 }
    /// 2025-05-22: a day in a DIFFERENT month, also past raw retention.
    var otherMonthDay: Int { day0 - 20 * 86400 }

    private func store(_ clock: Clock) -> HistoryStore { HistoryStore(root: dir, now: { clock.t }) }
    private func cp(_ ts: Int, soc: Int? = 80, watts: Double? = 10, onAC: Bool = true,
                    state: String = "charging") -> ChargePoint {
        ChargePoint(ts: ts, soc: soc, watts: watts, onAC: onAC, state: state, limit: 80)
    }
    private func rawURL(_ ts: Int) -> URL { dir.appendingPathComponent("charge-\(HistoryFormat.dayKey(ts)).jsonl") }
    private func aggURL(_ ts: Int) -> URL { dir.appendingPathComponent("agg-\(HistoryFormat.monthKey(ts)).json") }
    private func writeRaw(_ dayTs: Int, _ rows: [ChargePoint]) {
        let lines = rows.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
        try! (lines.joined(separator: "\n") + "\n").write(to: rawURL(dayTs), atomically: true, encoding: .utf8)
    }
    private func writeAggBytes(_ monthTs: Int, _ text: String) -> Data {
        let d = Data(text.utf8)
        try! d.write(to: aggURL(monthTs))
        return d
    }
    private func aggBytes(_ monthTs: Int) -> Data? { try? Data(contentsOf: aggURL(monthTs)) }
    private func rawExists(_ ts: Int) -> Bool { FileManager.default.fileExists(atPath: rawURL(ts).path) }
    private func aggExists(_ ts: Int) -> Bool { FileManager.default.fileExists(atPath: aggURL(ts).path) }
    private func decodedAgg(_ monthTs: Int) -> [String: HourlyAggregate]? {
        aggBytes(monthTs).flatMap { try? JSONDecoder().decode([String: HourlyAggregate].self, from: $0) }
    }
    private func hourKey(_ ts: Int) -> String { String(HistoryFormat.utcHourStart(ts)) }

    /// One valid hour, as the shipping encoder writes it, for `earlier` (June 2, 10:00 UTC).
    private var earlierHourJSON: String {
        "\"\(hourKey(earlier + 10 * 3600))\":{\"socMin\":40,\"socMax\":60,\"socAvg\":50,\"wattsAvg\":12,"
            + "\"acFraction\":0.8,\"dominantState\":\"charging\",\"count\":6}"
    }

    // MARK: - (a) an unreadable month is never written over

    /// Truncated JSON — a torn copy, a half-restored backup, a disk error. Present but undecodable.
    func testAnUndecodableMonthFileSurvivesMaintenanceByteForByte() {
        writeRaw(old, [cp(old + 5, soc: 70), cp(old + 3600 + 5, soc: 72)])
        let before = writeAggBytes(old, "{\(earlierHourJSON),\"\(hourKey(old + 99))\":{\"socMin\":")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(aggBytes(old), before,
                       "an unreadable month must be left exactly as it was — it holds days whose raw is gone")
    }

    /// Well-formed JSON in which one hour lacks a field every version has written (`count`). The
    /// whole-month decode fails, and the OTHER hour — a perfectly good one — is what the old code lost.
    func testAMonthWithOneUndecodableHourSurvivesMaintenanceByteForByte() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        let before = writeAggBytes(old,
            "{\(earlierHourJSON),\"\(hourKey(earlier + 11 * 3600))\":{\"acFraction\":1,\"dominantState\":\"charging\"}}")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(aggBytes(old), before)
    }

    /// The incoming day could not be folded, so its raw file is the ONLY copy of it — it must not be
    /// pruned, and the Day tab must still be able to show it (`series` reads raw first).
    func testTheIncomingDayIsKeptInItsRawFileWhenItsMonthIsUnreadable() {
        writeRaw(old, [cp(old + 5, soc: 70), cp(old + 3600 + 5, soc: 72)])
        _ = writeAggBytes(old, "not json at all")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(old), "a day that could not be folded in must not be pruned")
        XCTAssertEqual(s.series(range: old...(old + 86400)).map(\.ts), [old + 5, old + 3600 + 5],
                       "the day is still readable, at full resolution, from its raw file")
    }

    /// Refusing to fold is the same operational state the stall signal already names: an aggregate
    /// could not be written, so a raw day cannot be compacted. Silence is the defect class.
    func testAnUnreadableMonthRaisesTheMaintenanceStall() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(s.maintenanceStalled, "a refused fold is not a clean run")
    }

    /// Re-running is idempotent: the second, third … run still refuses, still keeps the raw, still
    /// leaves the bytes alone. (The old code's FIRST run did the damage; a fix that only survived one
    /// run would be no fix.)
    func testRepeatedRunsStillRefuseAndStillKeepTheRaw() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        let before = writeAggBytes(old, "[1,2,3]")
        let s = store(Clock(day0))
        for _ in 0..<3 { s.runMaintenance() }
        XCTAssertEqual(aggBytes(old), before)
        XCTAssertTrue(rawExists(old))
        XCTAssertTrue(s.maintenanceStalled)
    }

    /// The refusal is scoped to the unreadable month. A day in a healthy month folds and prunes as
    /// normal in the same run.
    func testAnUnreadableMonthDoesNotBlockAnotherMonth() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        writeRaw(otherMonthDay, [cp(otherMonthDay + 5, soc: 55)])
        let before = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(aggBytes(old), before)
        XCTAssertTrue(rawExists(old))
        XCTAssertFalse(rawExists(otherMonthDay), "the healthy month's day folded and was pruned")
        XCTAssertEqual(decodedAgg(otherMonthDay)?.keys.sorted(), [hourKey(otherMonthDay + 5)])
    }

    /// Recovery: once the unreadable file is gone (moved aside, restored, or aged out), the next run
    /// folds the kept day into a FRESH month, prunes its raw and clears the stall — no manual step.
    func testOnceTheUnreadableMonthIsGoneTheKeptDayFoldsAndTheStallClears() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(old))
        try! FileManager.default.removeItem(at: aggURL(old))
        s.runMaintenance()
        XCTAssertFalse(rawExists(old), "folded then pruned, now that the month can be written")
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5)])
        XCTAssertFalse(s.maintenanceStalled)
    }

    /// Self-healing without anyone acting: the existing 12-month aggregate retention prunes an
    /// unreadable month by AGE like any other (it is past the horizon either way), and the next run
    /// then folds — and the retention prunes — its kept raw days. The stuck state cannot outlive the
    /// aggregate horizon.
    func testAnUnreadableMonthPastRetentionAgesOutAndReleasesItsRawDays() {
        let ancient = day0 - 15 * 31 * 86400
        writeRaw(ancient, [cp(ancient + 5, soc: 70)])
        _ = writeAggBytes(ancient, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(ancient), "first run: the fold is refused, so the raw stays")
        XCTAssertFalse(aggExists(ancient), "first run: retention removes the unreadable month by age")
        s.runMaintenance()
        XCTAssertFalse(rawExists(ancient), "second run: the day folds into a fresh month and is pruned")
        XCTAssertFalse(s.maintenanceStalled)
    }

    // MARK: - (b) a future field cannot make every old month unreadable

    /// Bytes from a LATER release (a downgrade, a restored backup) carry a key this build does not know.
    /// They must decode, and the hour they describe must survive the fold.
    func testAMonthCarryingAnUnknownFieldStillMerges() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(old,
            "{\"\(hourKey(earlier + 10 * 3600))\":{\"socMin\":40,\"socMax\":60,\"socAvg\":50,\"wattsAvg\":12,"
            + "\"acFraction\":0.8,\"dominantState\":\"charging\",\"count\":6,\"limitHeldSeconds\":1200}}")
        let s = store(Clock(day0))
        s.runMaintenance()
        let month = decodedAgg(old)
        XCTAssertEqual(month?[hourKey(earlier + 10 * 3600)]?.count, 6, "the earlier day's hour survived")
        XCTAssertNotNil(month?[hourKey(old + 5)], "and the incoming day was folded in beside it")
        XCTAssertFalse(rawExists(old))
    }

    /// The upgrade shape: an hour that carries ONLY the fields every version has written (the optional
    /// ones are omitted whenever they were nil — synthesized `encode` uses `encodeIfPresent`).
    func testAMonthCarryingOnlyTheAlwaysWrittenFieldsStillMerges() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(old,
            "{\"\(hourKey(earlier + 10 * 3600))\":{\"acFraction\":0,\"dominantState\":\"unknown\",\"count\":1}}")
        let s = store(Clock(day0))
        s.runMaintenance()
        let month = decodedAgg(old)
        XCTAssertEqual(month?[hourKey(earlier + 10 * 3600)],
                       HourlyAggregate(socMin: nil, socMax: nil, socAvg: nil, wattsAvg: nil,
                                       acFraction: 0, dominantState: "unknown", count: 1))
        XCTAssertNotNil(month?[hourKey(old + 5)])
    }

    /// THE TRIPWIRE FOR THE NEXT AUTHOR. These bytes are FROZEN: exactly what every release since
    /// 4.G (`9f59d24`) has written, and so exactly what sits on disk on the owner's machine. If a
    /// field is added to `HourlyAggregate` and this stops decoding, every month on disk becomes
    /// unreadable on upgrade. Decode the new field with `decodeIfPresent` in the tolerant initializer —
    /// never edit this fixture to make it pass.
    func testTheFrozenV1MonthBytesStillDecode() throws {
        let v1 = #"{"1749549600":{"socMin":40,"socMax":60,"socAvg":50,"wattsAvg":-12.5,"acFraction":0.25,"dominantState":"discharging","count":6},"1749553200":{"acFraction":1,"dominantState":"limitHold","count":60}}"#
        let month = try JSONDecoder().decode([String: HourlyAggregate].self, from: Data(v1.utf8))
        XCTAssertEqual(month["1749549600"],
                       HourlyAggregate(socMin: 40, socMax: 60, socAvg: 50, wattsAvg: -12.5,
                                       acFraction: 0.25, dominantState: "discharging", count: 6))
        XCTAssertEqual(month["1749553200"],
                       HourlyAggregate(socMin: nil, socMax: nil, socAvg: nil, wattsAvg: nil,
                                       acFraction: 1, dominantState: "limitHold", count: 60))
    }

    /// The tolerant decoder is hand-written, so a field that is encoded but not decoded would be lost
    /// silently. A full-fidelity round trip is what catches that.
    func testEveryEncodedFieldSurvivesARoundTrip() throws {
        let full = HourlyAggregate(socMin: 41, socMax: 79, socAvg: 60.5, wattsAvg: -3.25,
                                   acFraction: 0.5, dominantState: "charging", count: 42)
        let back = try JSONDecoder().decode(HourlyAggregate.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(back, full)
    }

    // MARK: - the three-state read itself, and where the unreadable state surfaces

    /// The whole defect, as vocabulary: the old read had no way to say "there is a file and it will
    /// not decode" except `[:]`, which is also what "no file" said.
    func testTheThreeReadStatesAreDistinct() {
        let s = store(Clock(day0))
        let mk = HistoryFormat.monthKey(old)
        XCTAssertEqual(s.readAggregateMonth(mk), .missing)
        _ = writeAggBytes(old, "{}")
        XCTAssertEqual(s.readAggregateMonth(mk), .decoded([:]), "an empty month that DECODED is a real answer")
        _ = writeAggBytes(old, "{\(earlierHourJSON)}")
        XCTAssertEqual(s.readAggregateMonth(mk).hoursForDisplay.keys.sorted(), [hourKey(earlier + 10 * 3600)])
        _ = writeAggBytes(old, "{\"x\":")
        XCTAssertEqual(s.readAggregateMonth(mk), .unreadable)
        XCTAssertNotEqual(s.readAggregateMonth(mk), .missing)
        XCTAssertEqual(s.readAggregate(mk), [:], "the DISPLAY read still shows no hours for an unreadable month")
    }

    /// A file the process cannot open is not absent. And because the failure is about ACCESS, not the
    /// bytes, it is not memoised: once access is repaired the month reads again in the same session.
    func testAMonthFileThatCannotBeOpenedIsUnreadableNotMissing() {
        let s = store(Clock(day0))
        let mk = HistoryFormat.monthKey(old)
        _ = writeAggBytes(old, "{\(earlierHourJSON)}")
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: aggURL(old).path)
        XCTAssertEqual(s.readAggregateMonth(mk), .unreadable)
        writeRaw(old, [cp(old + 5, soc: 70)])
        XCTAssertFalse(s.aggregate(day: HistoryFormat.dayKey(old)), "no fold into a month that cannot be read")
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: aggURL(old).path)
        XCTAssertEqual(s.readAggregateMonth(mk).hoursForDisplay.keys.sorted(), [hourKey(earlier + 10 * 3600)],
                       "the repaired file is read again — the access failure was not cached")
    }

    /// `aggregate(day:)` called directly reports the refusal as "not durable" and writes nothing.
    func testAggregateDayReportsARefusedFoldAsNotDurable() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        let before = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        XCTAssertFalse(s.aggregate(day: HistoryFormat.dayKey(old)))
        XCTAssertEqual(aggBytes(old), before)
    }

    /// The honest surface: the month is NAMED (not just a generic stall), and the signal is a level —
    /// it clears by itself on the first run after the file is repaired or moved aside.
    func testAnUnreadableMonthIsNamedInTheSurfacedSetAndClearsOnRecovery() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        writeRaw(otherMonthDay, [cp(otherMonthDay + 5, soc: 55)])
        _ = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        XCTAssertEqual(s.unreadableAggregateMonths, [])
        s.runMaintenance()
        XCTAssertEqual(s.unreadableAggregateMonths, [HistoryFormat.monthKey(old)],
                       "only the unreadable month is named — the healthy one folded")
        try! FileManager.default.removeItem(at: aggURL(old))
        s.runMaintenance()
        XCTAssertEqual(s.unreadableAggregateMonths, [])
        XCTAssertFalse(s.maintenanceStalled)
    }

    /// Spec 30 §16 "32 · Health · history note": an unreadable month is a READ problem, not a write —
    /// it raises the stall but must not raise `aggregateWriteFailed` (that would make the note say
    /// "couldn't be saved" about a file that was never written).
    func testAnUnreadableMonthIsNotAFailedWrite() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(s.maintenanceStalled)
        XCTAssertFalse(s.aggregateWriteFailed, "nothing failed to write — the month would not read")
    }

    /// The month set names EVERY unreadable month file the run finds, not only one a fold was refused
    /// for: a month no raw day is folding into still hides its hours from the Health figures, so the
    /// note must say so. It does not raise the stall (nothing is kept uncompacted). A month past
    /// retention is pruned first and is not named.
    func testAnUnreadableMonthWithNoRawDayPendingIsNamedButIsNotAStall() {
        _ = writeAggBytes(otherMonthDay, "{")                       // 2025-05, no raw day of its own
        let ancient = day0 - 400 * 86400                            // 2024-05: past the aggregate horizon
        _ = writeAggBytes(ancient, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(s.unreadableAggregateMonths, [HistoryFormat.monthKey(otherMonthDay)])
        XCTAssertFalse(s.maintenanceStalled, "no raw day is being kept for it")
        XCTAssertFalse(aggExists(ancient), "fixture: the ancient month was pruned")
        _ = writeAggBytes(otherMonthDay, "{\"\(hourKey(otherMonthDay + 3600))\":{\"acFraction\":1,"
                          + "\"dominantState\":\"charging\",\"count\":1}}")
        s.runMaintenance()
        XCTAssertEqual(s.unreadableAggregateMonths, [], "repaired → no longer named")
    }

    /// The crossing day: a fold into an unreadable month is refused, and the SAME run's prune then
    /// deletes that month file (its last day just passed the horizon). The month is gone, so it must not
    /// be named — a name seeded from the refused fold would claim it for a whole day.
    func testAMonthRefusedAndThenPrunedInTheSameRunIsNotNamed() {
        let crossing = day0 - 376 * 86400                          // 2024-05-31: May ends before the cutoff
        XCTAssertEqual(HistoryFormat.dayKey(crossing), "2024-05-31")
        writeRaw(crossing, [cp(crossing + 5, soc: 70)])
        _ = writeAggBytes(crossing, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertFalse(aggExists(crossing), "fixture: the month was pruned in this run")
        XCTAssertTrue(rawExists(crossing), "fixture: its refused day was kept")
        XCTAssertEqual(s.unreadableAggregateMonths, [], "a deleted month is not named")
    }

    // MARK: - the note's read-side state is re-checked when Health appears (review fix 3)

    private func dirListing() -> [String: Data] {
        var out: [String: Data] = [:]
        for n in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            out[n] = (try? Data(contentsOf: dir.appendingPathComponent(n))) ?? Data()
        }
        return out
    }

    /// A month and a raw day named by maintenance, both repaired behind the store's back: the page's
    /// re-check (no maintenance run) stops naming them, so the note clears without waiting a day.
    func testARepairedFileStopsBeingNamedWhenHealthReChecks() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(otherMonthDay, "{")
        let rawDay = day0 - 12 * 86400
        _ = writeRawBytes(rawDay, Data((line(cp(rawDay + 5, soc: 60)) + "\n").utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(rawDay).path)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(s.unreadableAggregateMonths, [HistoryFormat.monthKey(otherMonthDay)])
        XCTAssertEqual(s.unreadableRawDays, [HistoryFormat.dayKey(rawDay)])
        let cal = Calendar(identifier: .gregorian)
        XCTAssertNotNil(HealthPageModel.historyNoteText(unreadableMonths: s.unreadableAggregateMonths,
                                                        unreadableRawDays: s.unreadableRawDays, writeFailed: false,
                                                        now: Date(timeIntervalSince1970: TimeInterval(day0)), calendar: cal))
        try! FileManager.default.removeItem(at: aggURL(otherMonthDay))                       // repaired: moved aside
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL(rawDay).path)
        s.refreshUnreadableHistory()                                                       // Health appears
        XCTAssertEqual(s.unreadableAggregateMonths, [])
        XCTAssertEqual(s.unreadableRawDays, [])
        XCTAssertNil(HealthPageModel.historyNoteText(unreadableMonths: s.unreadableAggregateMonths,
                                                     unreadableRawDays: s.unreadableRawDays, writeFailed: false,
                                                     now: Date(timeIntervalSince1970: TimeInterval(day0)), calendar: cal),
                     "the note clears")
    }

    /// The re-check reads; it never writes, folds or prunes. A day maintenance WOULD fold and prune, a
    /// month it WOULD prune, and an unreadable month are all left byte for byte — and the re-check names
    /// what maintenance would name (the unreadable month inside the horizon, not the one past it).
    func testTheReCheckWritesNothingAndNamesWhatMaintenanceWould() {
        writeRaw(old, [cp(old + 5, soc: 70)])                                  // maintenance would fold + prune
        _ = writeAggBytes(otherMonthDay, "{")                                  // unreadable, inside the horizon
        let ancient = day0 - 400 * 86400
        _ = writeAggBytes(ancient, "{")                                        // unreadable, past it (prunable)
        let before = dirListing()
        let s = store(Clock(day0))
        s.refreshUnreadableHistory()
        XCTAssertEqual(dirListing(), before, "no file written, folded or removed")
        XCTAssertEqual(s.unreadableAggregateMonths, [HistoryFormat.monthKey(otherMonthDay)])
        XCTAssertEqual(s.unreadableRawDays, [])
    }

    // MARK: - a history folder that cannot be listed (review fix 6)

    private let folderUnreadable = "History couldn\u{2019}t be read \u{2014} it\u{2019}s kept as is."
    private func noteNow(_ s: HistoryStore) -> String? {
        HealthPageModel.historyNoteText(for: s, now: Date(timeIntervalSince1970: TimeInterval(day0)),
                                        calendar: Calendar(identifier: .gregorian))
    }
    /// Write + search, no read: files open by path, but the folder cannot be listed.
    private func makeDirUnlistable() {
        try! FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: dir.path)
    }
    private func makeDirListable() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// An unlistable folder is not "nothing unreadable": maintenance raises `historyFolderUnreadable`,
    /// leaves the named months as they were (unknown, not cleared), and writes or prunes NOTHING on the
    /// strength of the failed listing — a day it would fold and prune, and a month it would prune, stay.
    func testAnUnlistableFolderIsNamedAndMaintenanceActsOnNothing() {
        defer { makeDirListable() }
        _ = writeAggBytes(otherMonthDay, "{")
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(s.unreadableAggregateMonths, [HistoryFormat.monthKey(otherMonthDay)])
        writeRaw(old, [cp(old + 5, soc: 70)])                         // would be folded, then pruned
        let ancient = day0 - 400 * 86400
        _ = writeAggBytes(ancient, "{}")                              // would be pruned
        makeDirUnlistable()
        s.runMaintenance()
        XCTAssertTrue(s.historyFolderUnreadable)
        XCTAssertEqual(s.unreadableAggregateMonths, [HistoryFormat.monthKey(otherMonthDay)],
                       "not cleared to \"nothing unreadable\" — the folder could not be looked at")
        XCTAssertTrue(rawExists(old), "no prune on a failed listing")
        XCTAssertFalse(aggExists(old), "no fold written on a failed listing")
        XCTAssertTrue(aggExists(ancient), "no aggregate prune on a failed listing")
        XCTAssertEqual(noteNow(s), folderUnreadable)
        makeDirListable()
        s.runMaintenance()
        XCTAssertFalse(s.historyFolderUnreadable, "listable again → cleared")
        XCTAssertFalse(rawExists(old), "and maintenance resumes: folded and pruned")
    }

    /// The Health re-check sees it too, and clears it once the folder lists again.
    func testTheReCheckNamesAnUnlistableFolder() {
        defer { makeDirListable() }
        let s = store(Clock(day0))
        makeDirUnlistable()
        s.refreshUnreadableHistory()
        XCTAssertTrue(s.historyFolderUnreadable)
        XCTAssertEqual(noteNow(s), folderUnreadable)
        makeDirListable()
        s.refreshUnreadableHistory()
        XCTAssertFalse(s.historyFolderUnreadable)
        XCTAssertNil(noteNow(s))
    }

    /// The display read runs inside SwiftUI bodies (`series`, `allAggregates`). An unreadable file must
    /// be decoded once per version of its bytes — not re-decoded (and re-logged) on every render.
    func testAnUnreadableMonthIsDecodedOncePerVersionNotOncePerRead() {
        _ = writeAggBytes(old, "{")
        let s = store(Clock(day0))
        let mk = HistoryFormat.monthKey(old)
        XCTAssertEqual(s.readAggregateMonth(mk), .unreadable)
        let afterFirst = s.fileDecodes
        for _ in 0..<20 { _ = s.series(range: old...(old + 86400)); _ = s.allAggregates() }
        XCTAssertEqual(s.fileDecodes, afterFirst, "the unreadable verdict is memoised on the file's stamp")
        _ = writeAggBytes(old, "{\(earlierHourJSON)}")      // repaired behind the store's back
        XCTAssertEqual(s.readAggregateMonth(mk).hoursForDisplay.count, 1, "a new version of the bytes is re-read")
    }

    // MARK: - (c) no regression: the legitimate cases still work

    /// No month file yet — the legitimate empty. The first fold creates it.
    func testAMissingMonthFileIsCreatedFresh() {
        writeRaw(old, [cp(old + 5, soc: 70), cp(old + 3600 + 5, soc: 72)])
        XCTAssertFalse(aggExists(old))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5), hourKey(old + 3600 + 5)].sorted())
        XCTAssertFalse(rawExists(old))
        XCTAssertFalse(s.maintenanceStalled)
    }

    /// A readable month is MERGED into, never replaced: the earlier day's hours sit beside the new ones.
    func testAReadableMonthKeepsItsEarlierDaysWhenADayIsFolded() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        _ = writeAggBytes(old, "{\(earlierHourJSON)}")
        let s = store(Clock(day0))
        s.runMaintenance()
        let month = decodedAgg(old)
        XCTAssertEqual(month?[hourKey(earlier + 10 * 3600)]?.count, 6)
        XCTAssertNotNil(month?[hourKey(old + 5)])
        XCTAssertFalse(rawExists(old))
        XCTAssertFalse(s.maintenanceStalled)
    }

    // MARK: - the raw-day mirror: an unreadable or partly undecodable RAW day is never pruned
    //
    // The same defect class on the other tier. `readLines` turned an unreadable raw file into `[]`
    // (`try? String(contentsOf:)`), which the fold read as "an empty day", and `compactMap` dropped
    // undecodable lines one by one. A day that folded its GOOD lines then passed `dayIsAggregated` and
    // was pruned — and the lines that did not decode went with it, for good.

    private func line(_ p: ChargePoint) -> String { String(data: try! JSONEncoder().encode(p), encoding: .utf8)! }
    private func writeRawBytes(_ dayTs: Int, _ data: Data) -> Data { try! data.write(to: rawURL(dayTs)); return data }
    private func rawBytes(_ dayTs: Int) -> Data? { try? Data(contentsOf: rawURL(dayTs)) }

    /// A line that is valid JSON but not a `ChargePoint` this build can decode (here: no `state`, a
    /// field every version has written — the stand-in for "a line this build cannot satisfy").
    func testARawDayWithAnUndecodableLineFoldsItsGoodLinesAndIsNotPruned() {
        let text = line(cp(old + 5, soc: 70)) + "\n"
            + "{\"ts\":\(old + 1805),\"soc\":71,\"onAC\":true}\n"
            + line(cp(old + 3600 + 5, soc: 72)) + "\n"
        let before = writeRawBytes(old, Data(text.utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(rawBytes(old), before, "the undecodable line must survive on disk, byte for byte")
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5), hourKey(old + 3600 + 5)].sorted(),
                       "the good lines were still folded into the month")
    }

    /// A torn line (a power loss mid-append) is malformed JSON. Same rule: fold the rest, keep the file.
    func testARawDayWithAMalformedLineIsNotPruned() {
        let text = line(cp(old + 5, soc: 70)) + "\n" + "{\"ts\":\(old + 60),\"so" + line(cp(old + 120)) + "\n"
        let before = writeRawBytes(old, Data(text.utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(rawBytes(old), before)
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5)])
    }

    /// One bad BYTE sequence must cost one line, not the whole day. `String(contentsOf:)` refuses the
    /// entire file on invalid UTF-8, so the old reader showed the day as empty.
    func testAnInvalidUTF8LineCostsOnlyThatLine() {
        var d = Data((line(cp(day0 + 5, soc: 70)) + "\n").utf8)
        d.append(contentsOf: [0x7B, 0xFF, 0xFE, 0x7D, 0x0A])          // "{\xFF\xFE}\n"
        d.append(Data((line(cp(day0 + 65, soc: 71)) + "\n").utf8))
        _ = writeRawBytes(day0, d)
        let s = store(Clock(day0 + 100))
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).map(\.ts), [day0 + 5, day0 + 65])
    }

    /// …and through maintenance: the day folds its good lines and keeps the file.
    func testARawDayWithAnInvalidUTF8LineFoldsTheRestAndIsNotPruned() {
        var d = Data((line(cp(old + 5, soc: 70)) + "\n").utf8)
        d.append(contentsOf: [0x7B, 0xFF, 0x7D, 0x0A])
        let before = writeRawBytes(old, d)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(rawBytes(old), before)
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5)])
    }

    /// A raw file the process cannot open is not an empty day: it raises the stall and is kept.
    func testAnUnreadableRawDayIsNotPrunedAndRaisesTheStall() {
        let before = writeRawBytes(old, Data((line(cp(old + 5, soc: 70)) + "\n").utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(old).path)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(old))
        XCTAssertTrue(s.maintenanceStalled, "an unreadable raw day is not a clean run")
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL(old).path)
        XCTAssertEqual(rawBytes(old), before)
    }

    /// Spec 30 §16 "32 · Health · history note": the unreadable raw day is NAMED (by its day key), apart
    /// from the generic stall, so the note can say "couldn't be read" — and it is not a failed write.
    /// Cleared once it reads again; a day released past the horizon is not named.
    func testAnUnreadableRawDayIsNamedAndClearsOnRecovery() {
        _ = writeRawBytes(old, Data((line(cp(old + 5, soc: 70)) + "\n").utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(old).path)
        let s = store(Clock(day0))
        XCTAssertEqual(s.unreadableRawDays, [])
        s.runMaintenance()
        XCTAssertEqual(s.unreadableRawDays, [HistoryFormat.dayKey(old)])
        XCTAssertFalse(s.aggregateWriteFailed, "a raw day that would not read is not a failed write")
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL(old).path)
        s.runMaintenance()
        XCTAssertEqual(s.unreadableRawDays, [])
    }

    func testAnUnreadableRawDayReleasedPastTheHorizonIsNotNamed() {
        let ancient = day0 - (HistoryStore.keptRawHorizonDays + 1) * 86400
        _ = writeRawBytes(ancient, Data((line(cp(ancient + 5, soc: 70)) + "\n").utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(ancient).path)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(s.unreadableRawDays, [])
    }

    /// The sharpest form: the month ALREADY holds this day's hours (an earlier partial fold), so the
    /// old `dayIsAggregated` gate said "aggregated" and deleted a raw file it had not even been able
    /// to read.
    func testAnUnreadableRawDayIsNotPrunedEvenWhenItsMonthAlreadyHasItsHours() {
        _ = writeRawBytes(old, Data((line(cp(old + 5, soc: 70)) + "\n" + line(cp(old + 7205, soc: 75)) + "\n").utf8))
        _ = writeAggBytes(old, "{\"\(hourKey(old + 5))\":{\"acFraction\":1,\"dominantState\":\"charging\",\"count\":1}}")
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(old).path)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(old), "a raw day that could not be read must never be pruned")
        XCTAssertTrue(s.maintenanceStalled)
    }

    /// Recovery: once the raw file is readable again, the next run folds it, prunes it, clears the stall.
    func testAnUnreadableRawDayFoldsAndPrunesOnceItCanBeRead() {
        _ = writeRawBytes(old, Data((line(cp(old + 5, soc: 70)) + "\n").utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(old).path)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(old))
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rawURL(old).path)
        s.runMaintenance()
        XCTAssertFalse(rawExists(old))
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5)])
        XCTAssertFalse(s.maintenanceStalled)
    }

    /// A kept, partly undecodable day is compacted for everything that decoded, so it is not a stall —
    /// otherwise one torn line from one power loss would hold the stall up for a year.
    func testAPartlyUndecodableRawDayDoesNotRaiseTheStall() {
        _ = writeRawBytes(old, Data((line(cp(old + 5, soc: 70)) + "\n{\"ts\":\n").utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertTrue(rawExists(old))
        XCTAssertFalse(s.maintenanceStalled)
    }

    /// The bound: a kept day is released once it ages past the aggregate horizon (12 × 31 days) —
    /// the same horizon at which its folded hours are themselves pruned. Without this one torn line
    /// would make its file the only unbounded thing in the store.
    func testAKeptRawDayIsReleasedOnceItAgesPastTheAggregateHorizon() {
        let ancient = day0 - (HistoryStore.aggRetentionMonths * 31 + 1) * 86400
        _ = writeRawBytes(ancient, Data((line(cp(ancient + 5, soc: 70)) + "\n{\"ts\":\n").utf8))
        let young = day0 - (HistoryStore.aggRetentionMonths * 31 - 1) * 86400
        _ = writeRawBytes(young, Data((line(cp(young + 5, soc: 70)) + "\n{\"ts\":\n").utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertFalse(rawExists(ancient), "past the horizon: released by retention")
        XCTAssertTrue(rawExists(young), "inside the horizon: still kept")
    }

    /// The same bound for a raw day that cannot be read at all.
    func testAnUnreadableRawDayIsReleasedOncePastTheAggregateHorizon() {
        let ancient = day0 - (HistoryStore.aggRetentionMonths * 31 + 1) * 86400
        _ = writeRawBytes(ancient, Data((line(cp(ancient + 5, soc: 70)) + "\n").utf8))
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: rawURL(ancient).path)
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertFalse(rawExists(ancient), "past the horizon: released by retention, readable or not")
        XCTAssertFalse(s.maintenanceStalled, "a released day is not a stall")
    }

    /// A raw day whose every line is undecodable still is not pruned (and folds nothing).
    func testARawDayOfOnlyUndecodableLinesIsNotPruned() {
        let before = writeRawBytes(old, Data("{\"ts\":1}\nnot json\n".utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(rawBytes(old), before)
        XCTAssertFalse(aggExists(old))
    }

    /// Lines from a LATER release carry a key this build does not know — they decode, fold, and the
    /// day is pruned normally.
    func testARawDayWhoseLinesCarryAnUnknownFieldFoldsAndPrunes() {
        _ = writeRawBytes(old, Data(("{\"ts\":\(old + 5),\"soc\":70,\"onAC\":true,\"state\":\"charging\",\"chargerW\":96}\n").utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertFalse(rawExists(old))
        XCTAssertEqual(decodedAgg(old)?.keys.sorted(), [hourKey(old + 5)])
    }

    /// THE TRIPWIRE for `ChargePoint`. These lines are FROZEN — the shape every release since 4.G
    /// (`9f59d24`) has appended, the optional fields omitted when nil. If a field is added and this
    /// stops decoding, every raw day on disk stops folding. Decode the new field with
    /// `decodeIfPresent` in the tolerant initializer — never edit this fixture to make it pass.
    func testTheFrozenV1ChargeLinesStillDecode() throws {
        let full = #"{"ts":1749600005,"soc":80,"watts":-12.5,"onAC":false,"state":"discharging","limit":80}"#
        let sparse = #"{"ts":1749600065,"onAC":true,"state":"unknown"}"#
        XCTAssertEqual(try JSONDecoder().decode(ChargePoint.self, from: Data(full.utf8)),
                       ChargePoint(ts: 1_749_600_005, soc: 80, watts: -12.5, onAC: false, state: "discharging", limit: 80))
        XCTAssertEqual(try JSONDecoder().decode(ChargePoint.self, from: Data(sparse.utf8)),
                       ChargePoint(ts: 1_749_600_065, soc: nil, watts: nil, onAC: true, state: "unknown", limit: nil))
    }

    func testEveryEncodedChargePointFieldSurvivesARoundTrip() throws {
        let p = ChargePoint(ts: 7, soc: 55, watts: 3.5, onAC: true, state: "limitHold", limit: 85)
        XCTAssertEqual(try JSONDecoder().decode(ChargePoint.self, from: JSONEncoder().encode(p)), p)
    }

    // MARK: - health.jsonl: the prune never deletes a line it could not decode
    //
    // `pruneHealth` rewrote the file from `readLines`, which (a) dropped every undecodable line and
    // (b) re-encoded every kept row — so a torn line, a bad byte, or a line from a schema this build
    // cannot satisfy was deleted at the first prune, and a kept row lost any field this build does not
    // know. With the synthesized `HealthPoint` decoder, one future required field would have made EVERY
    // old row undecodable and deleted the whole lifetime capacity-fade series in one rewrite.

    private var healthURL: URL { dir.appendingPathComponent("health.jsonl") }
    /// One health line, encoded as the store encodes (sorted keys) — so the bytes a test writes and the
    /// bytes it expects back are the same string. A plain `JSONEncoder` made the pass-through tests below
    /// flaky: two encodes of one value could order the keys differently.
    private func hp(_ ts: Int, _ pct: Double = 90) -> String {
        String(data: try! HistoryFormat.encoder().encode(HealthPoint(ts: ts, healthPct: pct, cycles: 100, maxCap_mAh: 5000)),
               encoding: .utf8)!
    }
    private func writeHealthBytes(_ d: Data) { try! d.write(to: healthURL) }
    private func healthLines() -> [Data] {
        ((try? Data(contentsOf: healthURL)) ?? Data()).split(separator: 0x0A).map { Data($0) }
    }
    /// 15 months old: past the 12 × 31-day health horizon, so a prune is due.
    var stale: Int { day0 - 15 * 31 * 86400 }
    /// 2 months old: inside the horizon.
    var fresh: Int { day0 - 2 * 31 * 86400 }

    /// A valid-JSON line this build cannot decode (no `ts`, the one field every version has written).
    func testAPruneKeepsAnUndecodableHealthLineVerbatim() {
        let bad = #"{"healthPct":88.5,"cycles":120}"#
        writeHealthBytes(Data([hp(stale), bad, hp(fresh)].joined(separator: "\n").appending("\n").utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(healthLines(), [Data(bad.utf8), Data(hp(fresh).utf8)],
                       "the stale row is dropped; the undecodable line survives byte for byte")
    }

    /// A torn append (power loss) is malformed JSON — same rule.
    func testAPruneKeepsAMalformedHealthLineVerbatim() {
        let torn = "{\"ts\":\(fresh + 60),\"heal"
        writeHealthBytes(Data([hp(stale), torn, hp(fresh)].joined(separator: "\n").appending("\n").utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(healthLines(), [Data(torn.utf8), Data(hp(fresh).utf8)])
    }

    /// One invalid UTF-8 sequence must cost one line. `String(contentsOf:)` refused the whole file, so
    /// the old prune never ran at all on such a file (and `healthSeries` showed nothing).
    func testAnInvalidUTF8HealthLineCostsOnlyThatLine() {
        var d = Data((hp(stale) + "\n").utf8)
        let badBytes = Data([0x7B, 0xFF, 0xFE, 0x7D])
        d.append(badBytes); d.append(0x0A)
        d.append(Data((hp(fresh) + "\n").utf8))
        writeHealthBytes(d)
        let s = store(Clock(day0))
        XCTAssertEqual(s.healthSeries().map(\.ts), [stale, fresh], "the readable rows still show")
        s.runMaintenance()
        XCTAssertEqual(healthLines(), [badBytes, Data(hp(fresh).utf8)],
                       "the stale row is pruned and the bad bytes pass through untouched")
    }

    /// A KEPT row is passed through, not re-encoded — so a field from a later release survives.
    func testAPruneDoesNotReEncodeTheRowsItKeeps() {
        let future = "{\"ts\":\(fresh),\"healthPct\":90,\"cycles\":100,\"maxCap_mAh\":5000,\"cellDeltaMv\":12}"
        writeHealthBytes(Data([hp(stale), future].joined(separator: "\n").appending("\n").utf8))
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(healthLines(), [Data(future.utf8)], "the kept row is the same bytes, unknown key and all")
    }

    /// A health file the process cannot read is never rewritten, and the prune does not claim the
    /// file is within its bound (it does not know).
    func testAnUnreadableHealthFileIsNeverRewritten() {
        let before = Data([hp(stale), hp(fresh)].joined(separator: "\n").appending("\n").utf8)
        writeHealthBytes(before)
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: healthURL.path)
        let s = store(Clock(day0))
        XCTAssertFalse(s.pruneHealth(todayStart: day0), "an unread file is not known to be within the bound")
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: healthURL.path)
        XCTAssertEqual(try? Data(contentsOf: healthURL), before)
    }

    /// The upgrade shape: a line with ONLY `ts` decodes (every other field was optional from day one).
    func testAHealthLineCarryingOnlyTheTimestampDecodes() throws {
        XCTAssertEqual(try JSONDecoder().decode(HealthPoint.self, from: Data(#"{"ts":5}"#.utf8)),
                       HealthPoint(ts: 5, healthPct: nil, cycles: nil, maxCap_mAh: nil))
    }

    /// THE TRIPWIRE for `HealthPoint`: frozen bytes as every release since 4.G (`9f59d24`) has
    /// appended them. Never edit this fixture to make it pass — decode a new field with `decodeIfPresent`.
    func testTheFrozenV1HealthLinesStillDecode() throws {
        let full = #"{"ts":1749600000,"healthPct":91.3,"cycles":412,"maxCap_mAh":5321}"#
        XCTAssertEqual(try JSONDecoder().decode(HealthPoint.self, from: Data(full.utf8)),
                       HealthPoint(ts: 1_749_600_000, healthPct: 91.3, cycles: 412, maxCap_mAh: 5321))
    }

    func testEveryEncodedHealthPointFieldSurvivesARoundTrip() throws {
        let p = HealthPoint(ts: 9, healthPct: 87.5, cycles: 3, maxCap_mAh: 4999)
        XCTAssertEqual(try JSONDecoder().decode(HealthPoint.self, from: JSONEncoder().encode(p)), p)
    }

    // MARK: - deterministic bytes: the store writes every JSON object with SORTED keys
    //
    // A plain `JSONEncoder` orders keys by a hash seeded per process — and, measured on this machine,
    // not always the same way twice within one process — so the same row could land as different bytes.
    // The store encodes through `HistoryFormat.encoder()` (`.sortedKeys`): one row, one byte string.
    // Readers are unaffected: the decoders read by key, and `scripts/capture-ncr-at-full.sh` matches
    // each key with its own regex.

    func testTheStoreWritesChargeAndHealthLinesWithSortedKeys() {
        let s = store(Clock(day0 + 100))
        s.ingest(HistorySample(soc: 80, watts: 10, onAC: true, state: "charging", limit: 80,
                               healthPct: 95, cycles: 100, maxCap_mAh: 5000))
        s.flush()
        XCTAssertEqual(rawBytes(day0).map { String(decoding: $0, as: UTF8.self) },
                       #"{"limit":80,"onAC":true,"soc":80,"state":"charging","ts":\#(day0 + 100),"watts":10}"# + "\n")
        XCTAssertEqual((try? Data(contentsOf: healthURL)).map { String(decoding: $0, as: UTF8.self) },
                       #"{"cycles":100,"healthPct":95,"maxCap_mAh":5000,"ts":\#(day0 + 100)}"# + "\n")
    }

    func testTheStoreWritesAMonthAggregateWithSortedKeys() {
        writeRaw(old, [cp(old + 5, soc: 70)])
        let s = store(Clock(day0))
        s.runMaintenance()
        XCTAssertEqual(aggBytes(old).map { String(decoding: $0, as: UTF8.self) },
                       #"{"\#(old)":{"acFraction":1,"count":1,"dominantState":"charging","socAvg":70,"#
                           + #""socMax":70,"socMin":70,"wattsAvg":10}}"#)
    }

    // MARK: - final review F8: the `.started` marker is three-state and never written over

    private var markerURL: URL { dir.appendingPathComponent(".started") }
    private func sample() -> HistorySample {
        HistorySample(soc: 80, watts: 10, onAC: true, state: "charging", limit: 80,
                      healthPct: nil, cycles: nil, maxCap_mAh: nil)
    }

    /// THE DEFECT. The marker was read with `try?`, so an unreadable or undecodable `.started` read as
    /// "never recorded", and the first ingest wrote `now` over it — the user's real "recording since"
    /// date replaced by today, silently.
    func testAnUndecodableMarkerIsNotWrittenOverByTheFirstIngest() {
        try! Data("not-a-timestamp".utf8).write(to: markerURL)
        let s = store(Clock(day0 + 100))
        s.ingest(sample())
        XCTAssertEqual(try? Data(contentsOf: markerURL), Data("not-a-timestamp".utf8))
        XCTAssertNil(s.recordingSince, "unknown, not today")
        XCTAssertTrue(s.recordingSinceUnreadable, "the store knows the marker was there and unreadable")
    }

    /// The same for a marker the process cannot open (an atomic write would REPLACE it, since the
    /// directory is writable).
    func testAnUnopenableMarkerIsNotReplacedByTheFirstIngest() {
        try! Data("1700000000".utf8).write(to: markerURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: markerURL.path)
        let s = store(Clock(day0 + 100))
        s.ingest(sample())
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
        XCTAssertEqual(try? Data(contentsOf: markerURL), Data("1700000000".utf8))
    }

    func testAReadableMarkerStillReadsAndAMissingOneIsStillWritten() {
        try! Data("1700000000\n".utf8).write(to: markerURL)
        XCTAssertEqual(store(Clock(day0)).recordingSince, Date(timeIntervalSince1970: 1_700_000_000))
        try! FileManager.default.removeItem(at: markerURL)
        let s = store(Clock(day0 + 100))
        XCTAssertNil(s.recordingSince)
        XCTAssertFalse(s.recordingSinceUnreadable, "a missing marker is the legitimate empty")
        s.ingest(sample())
        XCTAssertEqual(s.recordingSince, Date(timeIntervalSince1970: TimeInterval(day0 + 100)))
        XCTAssertEqual((try? String(contentsOf: markerURL, encoding: .utf8)), String(day0 + 100))
    }

    // MARK: - final review F8: an append never glues a good row onto a torn line

    /// A crash mid-append leaves a torn last line with no newline. The next append used to write straight
    /// after it, so its first good row was glued onto the torn bytes and became undecodable too — one
    /// crash cost two rows. A newline is now written first when the file does not end in one.
    func testAnAppendAfterATornTailStartsOnItsOwnLine() {
        let good = line(cp(day0 + 5, soc: 70))
        try! Data((good + "\n" + "{\"ts\":\(day0 + 65),\"so").utf8).write(to: rawURL(day0))   // torn, no "\n"
        let c = Clock(day0 + 200); let s = store(c)
        s.ingest(sample())
        s.flush()
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).map(\.ts), [day0 + 5, day0 + 200],
                       "the new row decodes — it was not glued onto the torn line")
        let text = (try? String(contentsOf: rawURL(day0), encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("{\"ts\":\(day0 + 65),\"so\n"), "the torn bytes are kept, on their own line")
    }

    /// No regression: a well-formed file gets no blank line inserted.
    func testAnAppendToAWellFormedFileAddsNoBlankLine() {
        try! Data((line(cp(day0 + 5, soc: 70)) + "\n").utf8).write(to: rawURL(day0))
        let c = Clock(day0 + 200); let s = store(c)
        s.ingest(sample())
        s.flush()
        let text = (try? String(contentsOf: rawURL(day0), encoding: .utf8)) ?? ""
        XCTAssertFalse(text.contains("\n\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }
}
