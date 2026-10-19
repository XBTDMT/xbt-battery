import XCTest

/// Sprint 4.G (#28): the full history-store test matrix (SPEC sec 5) — roundtrip, partial-tail,
/// rate bound + transition rows, flush seam, UTC rotation, aggregate math, aggregate-then-delete
/// kill-test, idempotence, retention, stitched tier-boundary read, health change-detection.
@MainActor
final class HistoryStoreTests: XCTestCase {

    var dir: URL!
    final class Clock { var t: Int; init(_ t: Int) { self.t = t } }

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("histtest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); super.tearDown() }

    // a UTC midnight (multiple of 86400) as the test epoch base
    let day0 = 1_749_600_000

    private func store(_ clock: Clock) -> HistoryStore { HistoryStore(root: dir, now: { clock.t }) }
    private func sample(soc: Int? = 80, watts: Double? = 10, onAC: Bool = true, state: String = "charging",
                        limit: Int? = 80, healthPct: Double? = 95, cycles: Int? = 100, maxCap: Int? = 5000)
    -> HistorySample {
        HistorySample(soc: soc, watts: watts, onAC: onAC, state: state, limit: limit,
                      healthPct: healthPct, cycles: cycles, maxCap_mAh: maxCap)
    }
    private func rawURL(_ ts: Int) -> URL { dir.appendingPathComponent("charge-\(HistoryFormat.dayKey(ts)).jsonl") }
    private func writeRaw(_ dayTs: Int, _ rows: [ChargePoint]) {
        let lines = rows.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
        try! (lines.joined(separator: "\n") + "\n").write(to: rawURL(dayTs), atomically: true, encoding: .utf8)
    }
    private func writeAgg(_ monthTs: Int, _ dict: [String: HourlyAggregate]) {
        try! JSONEncoder().encode(dict).write(to: dir.appendingPathComponent("agg-\(HistoryFormat.monthKey(monthTs)).json"))
    }
    private func aggExists(_ monthTs: Int) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("agg-\(HistoryFormat.monthKey(monthTs)).json").path)
    }
    private func rawExists(_ ts: Int) -> Bool { FileManager.default.fileExists(atPath: rawURL(ts).path) }
    private var healthURL: URL { dir.appendingPathComponent("health.jsonl") }
    private func healthLineCount() -> Int {
        ((try? String(contentsOf: healthURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { !$0.isEmpty }.count
    }
    private func writeHealth(_ rows: [HealthPoint]) {
        let lines = rows.map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
        try! (lines.joined(separator: "\n") + "\n").write(to: healthURL, atomically: true, encoding: .utf8)
    }
    private func cp(_ ts: Int, soc: Int? = 80, watts: Double? = 10, onAC: Bool = true, state: String = "charging") -> ChargePoint {
        ChargePoint(ts: ts, soc: soc, watts: watts, onAC: onAC, state: state, limit: 80)
    }

    // MARK: - roundtrip + flush seam

    func testAppendReadRoundtrip() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80))
        s.flush()
        let rows = s.series(range: day0...(day0 + 86400))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.ts, day0 + 100)
        XCTAssertEqual(rows.first?.soc, 80)
        XCTAssertEqual(rows.first?.state, "charging")
    }

    func testFlushOnQuitSeam_bufferedUntilFlush() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample())
        XCTAssertTrue(s.series(range: day0...(day0 + 86400)).isEmpty, "buffered — not yet on disk")
        s.flush()   // the quit/sleep seam
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 1, "flush persists the tail")
    }

    /// B-arc B5: the time-based auto-flush widened 60 s → 300 s. Rows stay buffered right up to the
    /// boundary and land on the first ingest past it — the explicit sleep/quit seam above is what bounds
    /// a normal exit, so this window only sizes the crash-loss exposure.
    func testTimeBasedAutoFlushHoldsUntilTheB5Window() {
        XCTAssertEqual(HistoryStore.flushSeconds, 300, "B5 widened the standing flush cadence")
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80))                                    // buffers; starts the flush clock
        c.t = day0 + 100 + HistoryStore.flushSeconds - 1
        s.ingest(sample(soc: 81))                                    // a transition row, still inside the window
        XCTAssertTrue(s.series(range: day0...(day0 + 86400)).isEmpty,
                      "nothing written yet — under the 300 s window (was written at 60 s before B5)")
        c.t = day0 + 100 + HistoryStore.flushSeconds
        s.ingest(sample(soc: 82))                                    // crosses the window → auto-flush
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 3, "the buffered tail lands at 300 s")
    }

    // MARK: - partial-tail tolerance

    func testPartialTailTolerated() {
        // two good lines + a truncated/garbage tail (a crash mid-write).
        let good = [cp(day0 + 1), cp(day0 + 2)].map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
        try! (good.joined(separator: "\n") + "\n" + "{\"ts\":3,\"soc\":4").write(to: rawURL(day0), atomically: true, encoding: .utf8)
        let c = Clock(day0); let s = store(c)
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 2, "the malformed tail line is skipped")
    }

    // MARK: - rate bound + transition rows

    func testRateBoundPlusTransitionRows() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80, state: "charging"))           // row1 (first)
        c.t = day0 + 110; s.ingest(sample(soc: 80, state: "charging"))   // skip (no transition, <60 s)
        c.t = day0 + 120; s.ingest(sample(soc: 81, state: "charging"))   // row2 (SoC step)
        c.t = day0 + 130; s.ingest(sample(soc: 81, state: "discharging")) // row3 (state change)
        c.t = day0 + 140; s.ingest(sample(soc: 81, onAC: false, state: "discharging")) // row4 (onAC flip)
        c.t = day0 + 145; s.ingest(sample(soc: 81, onAC: false, state: "discharging")) // skip
        c.t = day0 + 205; s.ingest(sample(soc: 81, onAC: false, state: "discharging")) // row5 (60 s elapsed)
        s.flush()
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 5)
    }

    // MARK: - UTC day rotation (storage is UTC; tz-independent by construction)

    func testUTCDayRotation_rowsLandByUTCAcrossMidnight() {
        let c = Clock(day0 - 30); let s = store(c)
        s.ingest(sample(soc: 79))                       // row in day (day0-1), 30 s before UTC midnight
        c.t = day0 + 30; s.ingest(sample(soc: 80))      // row in day (day0), 30 s after — same buffer
        s.flush()
        XCTAssertTrue(rawExists(day0 - 86400), "the pre-midnight row landed in the prior UTC day-file")
        XCTAssertTrue(rawExists(day0), "the post-midnight row landed in the new UTC day-file")
        // Neither duplicated nor lost: exactly one row each.
        XCTAssertEqual(s.series(range: (day0 - 86400)...(day0 + 86400)).count, 2)
    }

    // MARK: - aggregate math

    func testAggregateMath() {
        let h = day0   // hour-start
        writeRaw(day0, [cp(h + 10, soc: 80, watts: 10, onAC: true, state: "charging"),
                        cp(h + 20, soc: 82, watts: 20, onAC: true, state: "charging"),
                        cp(h + 30, soc: 84, watts: 30, onAC: false, state: "discharging")])
        let c = Clock(day0); let s = store(c)
        s.aggregate(day: HistoryFormat.dayKey(day0))
        let agg = decodeAgg(day0)[String(h)]
        XCTAssertNotNil(agg)
        XCTAssertEqual(agg?.socMin, 80); XCTAssertEqual(agg?.socMax, 84)
        XCTAssertEqual(agg?.socAvg ?? 0, 82, accuracy: 0.001)
        XCTAssertEqual(agg?.wattsAvg ?? 0, 20, accuracy: 0.001)
        XCTAssertEqual(agg?.acFraction ?? 0, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(agg?.dominantState, "charging")
        XCTAssertEqual(agg?.count, 3)
    }

    // MARK: - aggregate-then-delete (the kill-test)

    func testAggregateThenDelete_killMidJobLeavesRawIntact() {
        let old = day0 - 8 * 86400   // 8 days old → eligible
        writeRaw(old, [cp(old + 5, soc: 70), cp(old + 3600 + 5, soc: 72)])
        let c = Clock(day0); let s = store(c)
        // Simulate a kill AFTER aggregate, BEFORE delete: run only the aggregate step.
        s.aggregate(day: HistoryFormat.dayKey(old))
        XCTAssertTrue(rawExists(old), "raw MUST survive the aggregate step (no premature delete)")
        XCTAssertTrue(aggExists(old), "the aggregate was written first")
        // The full job then deletes (idempotent re-aggregate + delete).
        s.runMaintenance()
        XCTAssertFalse(rawExists(old), "now deleted — aggregate-then-delete completed")
        XCTAssertTrue(aggExists(old))
    }

    func testIdempotentReRun() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70), cp(old + 10, soc: 71)])
        let c = Clock(day0); let s = store(c)
        s.runMaintenance()
        let agg1 = decodeAgg(old)
        s.runMaintenance()   // second run: raw already gone; nothing to re-aggregate
        XCTAssertEqual(decodeAgg(old), agg1, "re-running is a no-op")
        XCTAssertFalse(rawExists(old))
    }

    // MARK: - retention

    func testRawRetention_7DayBoundary() {
        let keep = day0 - 7 * 86400   // exactly 7 days → kept
        let drop = day0 - 8 * 86400   // 8 days → aggregated + deleted
        writeRaw(keep, [cp(keep + 5, soc: 60)])
        writeRaw(drop, [cp(drop + 5, soc: 50)])
        let c = Clock(day0); let s = store(c)
        s.runMaintenance()
        XCTAssertTrue(rawExists(keep), "a 7-day-old raw file is kept")
        XCTAssertFalse(rawExists(drop), "an 8-day-old raw file is aggregated then deleted")
    }

    func testAggregateRetention_12Months() {
        let recentMonth = day0 - 2 * 31 * 86400          // ~2 months ago → kept
        let oldMonth = day0 - 15 * 31 * 86400            // ~15 months ago → pruned
        writeAgg(recentMonth, [String(recentMonth): HourlyAggregate(socMin: 50, socMax: 60, socAvg: 55, wattsAvg: 5, acFraction: 1, dominantState: "charging", count: 1)])
        writeAgg(oldMonth, [String(oldMonth): HourlyAggregate(socMin: 50, socMax: 60, socAvg: 55, wattsAvg: 5, acFraction: 1, dominantState: "charging", count: 1)])
        let c = Clock(day0); let s = store(c)
        s.runMaintenance()
        XCTAssertTrue(aggExists(recentMonth), "a ~2-month aggregate is kept")
        XCTAssertFalse(aggExists(oldMonth), "a ~15-month aggregate is pruned")
    }

    // MARK: - stitched read across a tier boundary

    func testStitchedRead_rawPlusAggregateTierBoundary() {
        let oldDay = day0 - 10 * 86400          // raw deleted → served from aggregate
        writeAgg(oldDay, [String(oldDay): HourlyAggregate(socMin: 40, socMax: 60, socAvg: 50, wattsAvg: 12, acFraction: 0.8, dominantState: "charging", count: 6)])
        writeRaw(day0, [cp(day0 + 100, soc: 90, state: "charging")])   // recent raw
        let c = Clock(day0 + 200); let s = store(c)
        let series = s.series(range: oldDay...(day0 + 86400))
        XCTAssertEqual(series.count, 2, "one synthesized agg point + one raw row, stitched")
        XCTAssertEqual(series.first?.ts, oldDay, "agg point first (older)")
        XCTAssertEqual(series.first?.soc, 50, "synthesized from socAvg")
        XCTAssertTrue(series.first?.onAC ?? false, "acFraction 0.8 ≥ 0.5 → onAC")
        XCTAssertEqual(series.last?.ts, day0 + 100, "raw row second (newer)")
        XCTAssertEqual(series.last?.soc, 90)
    }

    // MARK: - health change-detection

    func testHealthChangeDetectionRows() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 95, cycles: 100))                 // row1 (first)
        c.t = day0 + 200; s.ingest(sample(healthPct: 95, cycles: 100))  // same, same day → no row
        c.t = day0 + 300; s.ingest(sample(healthPct: 95, cycles: 101))  // cycles change → row2
        c.t = day0 + 86400 + 50; s.ingest(sample(healthPct: 95, cycles: 101))  // next UTC day → row3
        s.flush()
        let health = s.healthSeries()
        XCTAssertEqual(health.count, 3)
        XCTAssertEqual(health.map { $0.cycles }, [100, 101, 101])
    }

    // MARK: - A6: hysteresis deadband (the 0.1% grid could not hold a drifting signal)

    /// The measured production failure, replayed: `maxCap_mAh` jitters 5459…5498 while the battery's
    /// real health is flat, and the 5-sample rolling mean upstream turns that into a value that walks
    /// 87.4…88.0 continuously. Under 4.G's 0.1% grid that was ~200 rows/day; under the deadband the
    /// whole excursion is ONE row.
    func testJitteringMaxCapWithStableHealthWritesExactlyOneRow() {
        let c = Clock(day0 + 100); let s = store(c)
        let jitter: [(Double, Int)] = [(87.7, 5469), (87.8, 5492), (87.9, 5492), (87.8, 5462),
                                       (87.7, 5462), (87.6, 5459), (87.5, 5459), (87.4, 5460),
                                       (87.4, 5463), (87.7, 5493), (87.8, 5493), (87.9, 5493),
                                       (88.0, 5498), (87.9, 5474), (87.6, 5476), (87.7, 5480)]
        for (i, j) in jitter.enumerated() {
            c.t = day0 + 100 + i * 60          // 16 min of real samples, same UTC day, same cycle count
            s.ingest(sample(healthPct: j.0, cycles: 522, maxCap: j.1))
        }
        s.flush()
        let h = s.healthSeries()
        XCTAssertEqual(h.count, 1, "a 0.6%-wide jitter band (and a jittering maxCap_mAh) writes ONE row")
        XCTAssertEqual(h.first?.healthPct, 87.7)
        XCTAssertEqual(h.first?.maxCap_mAh, 5469, "maxCap_mAh rides along but never triggers a row")
    }

    func testHealthJitterInsideTheDeadbandWritesNoRow() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 86.11, cycles: 100))                       // → 86.1 (row1)
        // well past the rate bound, so ONLY the deadband can be what suppresses these
        c.t = day0 + 100 + 4 * HistoryStore.healthRateBound
        s.ingest(sample(healthPct: 86.94, cycles: 100))                       // +0.8% → inside 1.0%
        c.t = day0 + 100 + 8 * HistoryStore.healthRateBound
        s.ingest(sample(healthPct: 85.2, cycles: 100))                        // −0.9% → inside 1.0%
        s.flush()
        let h = s.healthSeries()
        XCTAssertEqual(h.count, 1, "sub-deadband drift writes no new row, in either direction")
        XCTAssertEqual(h.first?.healthPct, 86.1, "stored value is still the rounded 0.1%")
    }

    /// The deadband is measured against the last RECORDED row, not the previous sample — so a slow
    /// ramp of sub-deadband steps cannot creep a row out of the store one 0.1% at a time.
    func testSubDeadbandRampDoesNotAccumulateIntoARow() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 90.0, cycles: 100))
        for i in 1...9 {                                    // 90.0 → 90.9 in 0.1% steps, all same day
            c.t = day0 + 100 + i * HistoryStore.healthRateBound
            s.ingest(sample(healthPct: 90.0 + Double(i) / 10.0, cycles: 100))
        }
        s.flush()
        XCTAssertEqual(s.healthSeries().count, 1, "0.9% of creep is still inside the 1.0% deadband")
    }

    func testHealthRealMoveWritesRow() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 86.1, cycles: 100))
        c.t = day0 + 100 + HistoryStore.healthRateBound
        s.ingest(sample(healthPct: 85.1, cycles: 100))   // −1.0% → a real move, past the rate bound
        s.flush()
        XCTAssertEqual(s.healthSeries().map { $0.healthPct }, [86.1, 85.1])
    }

    /// A real move still obeys the rate bound: health is a months-scale signal, so a deadband-sized
    /// step arriving seconds after the last row waits rather than writing.
    func testRealMoveInsideTheRateBoundIsHeld() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 86.1, cycles: 100))
        c.t = day0 + 100 + HistoryStore.healthRateBound - 1
        s.ingest(sample(healthPct: 80.0, cycles: 100))   // −6.1%, but one second early
        s.flush()
        XCTAssertEqual(s.healthSeries().count, 1, "rate-bounded: no second row inside the hour")
        c.t = day0 + 100 + HistoryStore.healthRateBound
        s.ingest(sample(healthPct: 80.0, cycles: 100))
        s.flush()
        XCTAssertEqual(s.healthSeries().map { $0.healthPct }, [86.1, 80.0], "and lands on the boundary")
    }

    /// A health value appearing (or vanishing) is a state change, not drift — it writes immediately.
    func testHealthFieldAppearingWritesRow() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: nil, cycles: 100, maxCap: 5000))     // row1: cycles only
        c.t = day0 + 200; s.ingest(sample(healthPct: 88.0, cycles: 100))  // health appeared → row2
        s.flush()
        XCTAssertEqual(s.healthSeries().map { $0.healthPct }, [nil, 88.0])
    }

    func testHealthQuietDayStillWritesDailyRow() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 90.0, cycles: 100))                          // row1
        c.t = day0 + 86_400 + 50; s.ingest(sample(healthPct: 90.04, cycles: 100))  // → 90.0, but NEXT UTC day
        s.flush()
        XCTAssertEqual(s.healthSeries().count, 2, "a quiet day still writes its daily row")
    }

    func testHealthSkippedWhenAllFieldsNil() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: nil, cycles: nil, maxCap: nil))   // first snapshot, gauge not read
        s.flush()
        XCTAssertTrue(s.healthSeries().isEmpty, "no degenerate empty health row")
        c.t = day0 + 200; s.ingest(sample(healthPct: 90, cycles: 50, maxCap: 5000))
        s.flush()
        XCTAssertEqual(s.healthSeries().count, 1, "the first row with real data is recorded")
    }

    // MARK: - A6: health rows are BUFFERED (was one FileHandle open/seek/write/close per row)

    func testHealthRowsAreBufferedUntilAFlush() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 90, cycles: 100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: healthURL.path),
                       "no file handle opened per row — the row is buffered")
        XCTAssertTrue(s.healthSeries().isEmpty, "disk is the read truth, as for charge rows")
        s.flush()                                            // the quit/sleep seam drains health too
        XCTAssertEqual(s.healthSeries().count, 1)
    }

    /// A burst of health rows lands as ONE append, not one write per row.
    func testHealthBurstFlushesAsASingleBatch() {
        let c = Clock(day0 + 100); let s = store(c)
        for i in 0..<5 {                                     // cycle ticks: 5 rows, same day
            c.t = day0 + 100 + i * 10
            s.ingest(sample(healthPct: 90, cycles: 100 + i))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: healthURL.path), "still buffered")
        s.flush()
        XCTAssertEqual(healthLineCount(), 5, "all five rows landed in one append, in order")
        XCTAssertEqual(s.healthSeries().map { $0.cycles }, [100, 101, 102, 103, 104])
    }

    /// The time-based auto-flush drains health as well as charge (no separate health timer).
    func testHealthAutoFlushesOnTheStandingFlushCadence() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 90, cycles: 100))
        XCTAssertTrue(s.healthSeries().isEmpty)
        c.t = day0 + 100 + HistoryStore.flushSeconds
        s.ingest(sample(healthPct: 90, cycles: 100))         // crosses the window → auto-flush
        XCTAssertEqual(s.healthSeries().count, 1, "the buffered health row lands on the 300 s flush")
    }

    /// S2 contract preserved: a failed health flush re-buffers the row (it is not marked written and
    /// then lost), and it self-heals on the next writable flush — exactly once.
    func testHealthFlushFailureReBuffersThenSelfHeals_S2() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 90, cycles: 100))
        makeRootReadOnly()
        s.flush()
        XCTAssertTrue(s.healthSeries().isEmpty, "a failed health flush persists nothing")
        makeRootWritable()
        s.flush()
        XCTAssertEqual(s.healthSeries().count, 1, "the re-buffered health row persists after recovery")
        s.flush()
        XCTAssertEqual(s.healthSeries().count, 1, "drained on success — not re-appended")
    }

    // MARK: - A6: health retention (health.jsonl was 'NEVER pruned' — unbounded by design)

    func testHealthRetention_12MonthBoundary() {
        let recent = day0 - 2 * 31 * 86400            // ~2 months old → kept
        let old = day0 - 15 * 31 * 86400              // ~15 months old → pruned
        writeHealth([HealthPoint(ts: old, healthPct: 95, cycles: 10, maxCap_mAh: 5000),
                     HealthPoint(ts: recent, healthPct: 90, cycles: 400, maxCap_mAh: 4800)])
        let c = Clock(day0); let s = store(c)
        s.runMaintenance()
        XCTAssertEqual(s.healthSeries().map { $0.ts }, [recent],
                       "rows past the 12-month horizon are dropped; recent rows survive")
    }

    /// The prune is a no-op WRITE on a young file — it must not rewrite 1.2 MB every maintenance run
    /// just to keep every row. (This is what makes it safe to bolt onto the frozen maintenance job.)
    func testHealthRetentionDoesNotRewriteAYoungFile() {
        writeHealth([HealthPoint(ts: day0 - 86400, healthPct: 90, cycles: 100, maxCap_mAh: 5000)])
        let before = try! FileManager.default.attributesOfItem(atPath: healthURL.path)[.modificationDate] as! Date
        let c = Clock(day0); let s = store(c)
        XCTAssertTrue(s.pruneHealth(todayStart: day0), "in-horizon file is already within the bound")
        let after = try! FileManager.default.attributesOfItem(atPath: healthURL.path)[.modificationDate] as! Date
        XCTAssertEqual(before, after, "nothing old enough to drop → the file is not rewritten at all")
    }

    // MARK: - B9 re-filed · pruneHealth read 1.2 MB to discover it had nothing to do
    //
    // The audit's original attribution ("history I/O blocks launch, including runMaintenance()") was
    // WRONG and was re-filed: aggregation is near-free in steady state (7-day retention leaves zero
    // eligible files). The launch cost is THIS method reading every row of `health.jsonl` — 18,084 rows
    // / 1.2 MB / 40 ms on the owner's machine — and then early-returning WITHOUT WRITING, because on a
    // 12-month horizon nothing is old enough to drop and will not be for the best part of a year.
    // `fileDecodes` is the oracle the memo work already installed: it counts FULL file decodes.

    func testHealthRetention_youngFileIsNotEvenDecoded() {
        writeHealth([HealthPoint(ts: day0 - 86400, healthPct: 90, cycles: 100, maxCap_mAh: 5000),
                     HealthPoint(ts: day0 - 3600, healthPct: 90, cycles: 101, maxCap_mAh: 5000)])
        let c = Clock(day0); let s = store(c)
        let before = s.fileDecodes
        XCTAssertTrue(s.pruneHealth(todayStart: day0))
        XCTAssertEqual(s.fileDecodes, before,
                       "nothing is old enough to drop — proving that must not cost a full decode of the file")
    }

    /// …and the cheap check must not become a way to MISS a prune. The oldest row is the first line, so
    /// when it IS past the horizon the full read still runs and still rewrites.
    func testHealthRetention_oldFirstRowStillPaysForTheFullReadAndPrunes() {
        let old = day0 - 15 * 31 * 86400
        let recent = day0 - 2 * 31 * 86400
        writeHealth([HealthPoint(ts: old, healthPct: 95, cycles: 10, maxCap_mAh: 5000),
                     HealthPoint(ts: recent, healthPct: 90, cycles: 400, maxCap_mAh: 4800)])
        let c = Clock(day0); let s = store(c)
        let before = s.fileDecodes
        XCTAssertTrue(s.pruneHealth(todayStart: day0))
        XCTAssertGreaterThan(s.fileDecodes, before, "there was work to do, so the file is read")
        XCTAssertEqual(s.healthSeries().map { $0.ts }, [recent])
    }

    /// A first line the fast path cannot read is NOT evidence that there is nothing to prune. It must
    /// fall through to the full read. (That read no longer "repairs" the file by dropping the bad line:
    /// since `d21d862` the prune passes every line it cannot decode through verbatim — see
    /// `HistoryAggregateReadTests.testAPruneKeepsAnUndecodableHealthLineVerbatim`.)
    func testHealthRetention_unreadableFirstLineFallsThroughToTheFullRead() {
        let old = day0 - 15 * 31 * 86400
        let recent = day0 - 2 * 31 * 86400
        let good = [HealthPoint(ts: old, healthPct: 95, cycles: 10, maxCap_mAh: 5000),
                    HealthPoint(ts: recent, healthPct: 90, cycles: 400, maxCap_mAh: 4800)]
            .map { String(data: try! JSONEncoder().encode($0), encoding: .utf8)! }
        try! (["{not json"] + good).joined(separator: "\n").appending("\n")
            .write(to: healthURL, atomically: true, encoding: .utf8)
        let c = Clock(day0); let s = store(c)
        XCTAssertTrue(s.pruneHealth(todayStart: day0))
        XCTAssertEqual(s.healthSeries().map { $0.ts }, [recent],
                       "an undecodable first line must not be read as \"nothing to do\"")
    }

    /// Retention must not race the buffer: a row still in RAM is flushed first, then age-filtered.
    func testHealthRetentionFlushesTheBufferBeforePruning() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: 90, cycles: 100))          // buffered only
        s.runMaintenance()
        XCTAssertEqual(s.healthSeries().count, 1, "the buffered row was flushed, not pruned away")
    }

    /// The frozen aggregate-then-delete gating is untouched by the added health step.
    func testHealthRetentionDoesNotDisturbAggregateThenDelete() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70)])
        writeHealth([HealthPoint(ts: day0 - 15 * 31 * 86400, healthPct: 95, cycles: 10, maxCap_mAh: 5000)])
        let c = Clock(day0); let s = store(c)
        s.runMaintenance()
        XCTAssertFalse(rawExists(old), "raw still aggregated-then-deleted")
        XCTAssertTrue(aggExists(old))
        XCTAssertFalse(s.maintenanceStalled, "a health prune does not feed the aggregate stall signal")
        XCTAssertTrue(s.healthSeries().isEmpty, "and the out-of-horizon health row was pruned")
    }

    func testRecordingSinceStampedOnFirstIngest() {
        let c = Clock(day0 + 100); let s = store(c)
        XCTAssertNil(s.recordingSince)
        s.ingest(sample())
        XCTAssertEqual(s.recordingSince, Date(timeIntervalSince1970: TimeInterval(day0 + 100)))
        // persists across a re-open
        let s2 = store(Clock(day0 + 999))
        XCTAssertEqual(s2.recordingSince, Date(timeIntervalSince1970: TimeInterval(day0 + 100)))
    }

    // MARK: - S2 / S3: swallowed-write silent failures (failure injection via POSIX perms on root)

    // Tests run as the user, so POSIX perms are honored: a read-only root (no write bit) makes every
    // file create / FileHandle-append / atomic-aggregate write under it fail deterministically.
    private func makeRootReadOnly() { try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path) }
    private func makeRootWritable() { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

    // T6 (inspection-backed): the existing-file branch's seekToEnd is now a HARD fail — on a stale/unknown
    // offset append() returns false WITHOUT writing (prevents earlier-row corruption), rather than writing
    // at a bad offset. A real seekToEnd failure on a valid handle is not FS-injectable, so this rests on the
    // guard + the append-returns-false behavior that T1/T2 (flush) and T4 (aggregate) already exercise — not
    // a faked injection.

    // T1: a failed flush persists NOTHING (the row is re-buffered, not half-written).
    func testFlushWriteFailurePersistsNothing_S2() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80))                       // buffers 1 charge + 1 health row (.started written)
        makeRootReadOnly()
        s.flush()                                       // append fails → row re-buffered, NOT dropped
        XCTAssertTrue(s.series(range: day0...(day0 + 86400)).isEmpty, "a failed flush persists nothing")
        makeRootWritable()                              // restore for teardown
    }

    // T2: transient failure self-heals — the re-buffered row persists on the next (writable) flush, once.
    func testFlushTransientFailureReBuffersThenSelfHeals_S2() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80))
        makeRootReadOnly()
        s.flush()                                       // fails → re-buffered (pre-fix: removeAll drops it)
        makeRootWritable()
        s.flush()                                       // re-buffered row now persists
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 1, "the re-buffered row persists after recovery")
        s.flush()                                       // buffer was drained on success → no duplicate re-append
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 1, "buffer emptied on success — not re-appended")
    }

    // T3: soft RAM cap — under sustained write failure the buffer is bounded to bufferCap, newest retained.
    // The charge file is kept NON-existent throughout (read-only root from the start), so every flush hits
    // the new-file branch that the read-only root blocks — a read-only root does NOT block FileHandle
    // appends to an already-created file (file perms govern that), so we must never let the file exist here.
    func testFlushSoftRAMCapDropsOldestKeepsNewest_S2() {
        let c = Clock(day0 + 100)
        let s = HistoryStore(root: dir, now: { c.t }, bufferCap: 5)
        makeRootReadOnly()
        var overflowTs: [Int] = []
        for i in 0..<8 { c.t = day0 + 100 + i * 60; overflowTs.append(c.t); s.ingest(sample(soc: 80 - i)) }
        s.flush()                                       // sustained failure → buffer capped to the NEWEST 5
        makeRootWritable()
        s.flush()                                       // persist the capped buffer (file created fresh)
        let persisted = s.series(range: day0...(day0 + 86400)).map { $0.ts }.sorted()
        XCTAssertEqual(persisted.count, 5, "bufferCap=5 — the 3 oldest of the 8 overflow rows were dropped")
        XCTAssertEqual(persisted, Array(overflowTs.suffix(5)), "the NEWEST 5 are retained, in order")
        XCTAssertFalse(persisted.contains(overflowTs[0]), "the OLDEST overflow row was dropped (bounded loss)")
    }

    // T4: a stalled aggregate sets the flag AND keeps the raw (delete-gating holds → no loss).
    func testAggregateStallSetsFlagAndKeepsRaw_S3() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70)])
        let c = Clock(day0); let s = store(c)
        makeRootReadOnly()
        s.runMaintenance()
        XCTAssertTrue(s.maintenanceStalled, "a failed aggregate write sets the stall signal")
        XCTAssertTrue(rawExists(old), "delete-gating held — the raw is NOT deleted on a failed aggregate")
        makeRootWritable()
    }

    // T5: the stall self-clears on recovery and the normal aggregate-then-delete path resumes.
    func testAggregateStallSelfClearsOnRecovery_S3() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70)])
        let c = Clock(day0); let s = store(c)
        makeRootReadOnly()
        s.runMaintenance()
        XCTAssertTrue(s.maintenanceStalled)
        makeRootWritable()
        s.runMaintenance()
        XCTAssertFalse(s.maintenanceStalled, "a clean run clears the stall signal")
        XCTAssertFalse(rawExists(old), "now aggregated-then-deleted (normal path intact)")
        XCTAssertTrue(aggExists(old))
    }

    // Review fix 4: a raw row that could not be APPENDED lives only in RAM (capped, lost on quit) — the
    // note must say new readings may be lost. `rawWriteFailed` is raised by a failed charge OR health
    // append and cleared by the next flush in which everything lands.
    func testAFailedRawFlushRaisesRawWriteFailedAndTheNextGoodFlushClearsIt() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample())
        makeRootReadOnly()
        s.flush()
        XCTAssertTrue(s.rawWriteFailed, "the charge row could not be appended")
        XCTAssertEqual(HealthPageModel.historyNoteText(for: s, now: Date(timeIntervalSince1970: TimeInterval(day0)),
                                                      calendar: Calendar(identifier: .gregorian)),
                       "History couldn\u{2019}t be saved \u{2014} new readings may be lost until it can.")
        makeRootWritable()
        s.flush()
        XCTAssertFalse(s.rawWriteFailed, "everything landed")
        XCTAssertNil(HealthPageModel.historyNoteText(for: s, now: Date(timeIntervalSince1970: TimeInterval(day0)),
                                                    calendar: Calendar(identifier: .gregorian)))
    }

    func testAFailedHealthAppendAloneRaisesRawWriteFailed() {
        try! Data().write(to: healthURL)
        try! FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: healthURL.path)
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample())
        s.flush()
        XCTAssertTrue(rawExists(day0), "fixture: the charge row landed")
        XCTAssertTrue(s.rawWriteFailed, "the health row did not")
        try! FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: healthURL.path)
        s.flush()
        XCTAssertFalse(s.rawWriteFailed)
    }

    // Spec 30 §16 "32 · Health · history note": the stall has three causes, and only a failed WRITE may be
    // called "couldn't be saved". `aggregateWriteFailed` names that cause alone, and clears on recovery.
    func testAFailedAggregateWriteIsNamedApartFromTheStallAndClearsOnRecovery() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70)])
        let c = Clock(day0); let s = store(c)
        XCTAssertFalse(s.aggregateWriteFailed)
        makeRootReadOnly()
        s.runMaintenance()
        XCTAssertTrue(s.aggregateWriteFailed, "a month aggregate could not be written")
        makeRootWritable()
        s.runMaintenance()
        XCTAssertFalse(s.aggregateWriteFailed, "a clean run clears it")
    }

    // MARK: - B5: a row the encoder rejects must not become a junk `{}` line

    /// `HistoryFormat.watts` is the twin of `WattageReadout.compact` / `.label`, which both guard a
    /// non-finite voltage (`758330e`). Without the same guard a NaN volt reading yields NaN watts,
    /// `JSONEncoder` throws on it, and the row lands in history as a literal `{}`.
    func testWattsNilOnNonFiniteVoltage() {
        XCTAssertNil(HistoryFormat.watts(voltageVolts: .nan, amperageMilliamps: 5000),
                     "NaN volts is a MISSING watts value, not a NaN one")
        XCTAssertNil(HistoryFormat.watts(voltageVolts: .infinity, amperageMilliamps: 5000))
        XCTAssertNil(HistoryFormat.watts(voltageVolts: -.infinity, amperageMilliamps: 5000))
        XCTAssertNil(HistoryFormat.watts(voltageVolts: nil, amperageMilliamps: 5000))
        XCTAssertNil(HistoryFormat.watts(voltageVolts: 12.4, amperageMilliamps: nil))
        XCTAssertEqual(HistoryFormat.watts(voltageVolts: 12.4, amperageMilliamps: 5000), 62.0,
                       "a finite reading is unchanged by the guard")
    }

    /// B5: the encoder is the last line of defence. A row that cannot be encoded must NOT be written as
    /// a literal `{}` and counted as a landed row — the reader drops that line as junk, so the row is a
    /// SILENT history gap. It is dropped instead, the drop is counted, and its neighbours still land.
    func testUnencodableChargeRowIsNotWrittenAsEmptyJSON_B5() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80, watts: .nan))        // pre-guard NaN, forced in through the sample seam
        c.t = day0 + 200
        s.ingest(sample(soc: 79, watts: 10))          // a good row in the SAME day group
        s.flush()
        let raw = (try? String(contentsOf: rawURL(day0), encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("{}"), "a failed encode must never land as a literal {} row")
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).map { $0.ts }, [day0 + 200],
                       "the good row still lands; only the unencodable row is dropped")
        XCTAssertEqual(s.unencodableRowsDropped, 1, "the drop is OBSERVABLE, not silent")
        s.flush()
        XCTAssertEqual(s.unencodableRowsDropped, 1,
                       "an unencodable row is dropped once — never re-buffered and retried forever")
    }

    /// The health file carries the same shape (`health.jsonl` shares `encode`).
    func testUnencodableHealthRowIsNotWrittenAsEmptyJSON_B5() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(healthPct: .nan, cycles: 100))
        s.flush()
        let raw = (try? String(contentsOf: healthURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(raw.contains("{}"), "a failed encode must never land as a literal {} health row")
        XCTAssertTrue(s.healthSeries().isEmpty, "nothing junk persisted")
        XCTAssertEqual(s.unencodableRowsDropped, 1, "the drop is OBSERVABLE, not silent")
        s.flush()
        XCTAssertEqual(s.unencodableRowsDropped, 1, "drained, not retried forever")
    }

    private func decodeAgg(_ ts: Int) -> [String: HourlyAggregate] {
        let url = dir.appendingPathComponent("agg-\(HistoryFormat.monthKey(ts)).json")
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: HourlyAggregate].self, from: d)) ?? [:]
    }

    // MARK: - B9: the decode memo (`series()` is consumed from a computed SwiftUI view property)

    /// THE DEFECT. `BatteryPopoverView.d6HistoryCard` calls `history.series(range:)` inline in a
    /// `@ViewBuilder` body, so the whole 24 h window is re-decoded on every body evaluation of a page
    /// its own author describes as re-rendering "on every published telemetry change". Measured: 3.8 ms
    /// of main-actor JSON decoding per call over ~1,376 real rows. Repeated reads of an UNCHANGED file
    /// must decode it once.
    func testRepeatedSeriesReadsDecodeTheFileOnce() {
        writeRaw(day0, (0..<50).map { cp(day0 + $0 * 60, soc: 80) })
        let c = Clock(day0 + 86_000); let s = store(c)
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 50)
        let afterFirst = s.fileDecodes
        XCTAssertGreaterThan(afterFirst, 0, "the first read really did decode the file")
        for _ in 0..<20 { XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 50) }
        XCTAssertEqual(s.fileDecodes, afterFirst, "20 further renders decode nothing — the memo held")
    }

    /// The range moves every second in the real caller (`now` is recomputed per render), so the memo
    /// must be keyed on the FILE, not the request. A memo keyed on the range would miss almost always.
    func testMemoSurvivesAMovingRange() {
        writeRaw(day0, (0..<50).map { cp(day0 + $0 * 60, soc: 80) })
        let c = Clock(day0 + 86_000); let s = store(c)
        _ = s.series(range: day0...(day0 + 86400))
        let afterFirst = s.fileDecodes
        for i in 1...10 { _ = s.series(range: (day0 + i)...(day0 + 86400 + i)) }
        XCTAssertEqual(s.fileDecodes, afterFirst, "a different range every call still reuses the decode")
    }

    /// …and the memo must never serve stale rows. A write THROUGH the store invalidates it.
    func testMemoIsInvalidatedByTheStoresOwnWrites() {
        let c = Clock(day0 + 100); let s = store(c)
        s.ingest(sample(soc: 80)); s.flush()
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 1)
        c.t = day0 + 300
        s.ingest(sample(soc: 60, state: "discharging")); s.flush()
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 2,
                       "the appended row is visible immediately — no stale memo")
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).last?.soc, 60)
    }

    /// …and by a change made BEHIND the store's back (the `(size, mtime)` key, not just the explicit
    /// invalidation). This is the guarantee that lets the memo exist at all.
    func testMemoIsInvalidatedByAnExternalRewrite() {
        writeRaw(day0, [cp(day0 + 10, soc: 80)])
        let c = Clock(day0 + 100); let s = store(c)
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 1)
        writeRaw(day0, [cp(day0 + 10, soc: 80), cp(day0 + 20, soc: 81), cp(day0 + 30, soc: 82)])
        XCTAssertEqual(s.series(range: day0...(day0 + 86400)).count, 3,
                       "a file rewritten by anything at all is re-decoded")
    }

    /// A deleted raw day must fall through to the aggregate tier, not keep answering from RAM.
    func testMemoDoesNotSurviveTheRawDayItDecoded() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70), cp(old + 3600 + 5, soc: 72)])
        let c = Clock(day0); let s = store(c)
        XCTAssertEqual(s.series(range: old...(old + 86400)).count, 2, "served from raw")
        s.runMaintenance()                       // aggregates, then deletes the raw
        XCTAssertFalse(rawExists(old))
        let after = s.series(range: old...(old + 86400))
        XCTAssertEqual(after.count, 2, "now served from the aggregate tier (2 hourly points)")
        XCTAssertEqual(after.map(\.ts), [HistoryFormat.utcHourStart(old + 5),
                                        HistoryFormat.utcHourStart(old + 3600 + 5)],
                       "hourly aggregate timestamps, not the memoised raw rows")
    }

    /// The aggregate tier is memoised on the same key — and `runMaintenance` reads it twice per pruned
    /// day (`aggregate` then `dayIsAggregated`), so a stale one would break the aggregate-then-delete
    /// data-loss guard. Re-running must stay idempotent and must still see its own write.
    func testAggregateMemoSeesTheStoresOwnAggregateWrite() {
        let old = day0 - 8 * 86400
        writeRaw(old, [cp(old + 5, soc: 70)])
        let c = Clock(day0); let s = store(c)
        _ = s.series(range: old...(old + 86400))     // warms the (empty) aggregate memo for that month
        s.runMaintenance()
        XCTAssertFalse(rawExists(old), "the freshly written aggregate was seen by dayIsAggregated")
        XCTAssertTrue(aggExists(old))
    }

    // MARK: - B5: the dropped-row counter has a SCREEN, not an allowlist entry

    func testHistoryRowsDroppedCopyIsSingularForOneAndPluralOtherwise() {
        // The count is in the copy because "1 row" and "400 rows" are different problems, and the
        // popover renders this verbatim next to the maintenance-stalled line.
        let one = PopoverDetailStrings.historyRowsDropped(1)
        XCTAssertTrue(one.hasPrefix("1 history row "), one)
        XCTAssertFalse(one.contains("rows"), "singular copy must not say \"rows\"")

        let many = PopoverDetailStrings.historyRowsDropped(7)
        XCTAssertTrue(many.hasPrefix("7 history rows "), many)
    }

    func testHistoryRowsDroppedCopySaysWhatWasActuallyLost() {
        // The honesty bar this line exists to meet: dropping is the CORRECT outcome, but it is still
        // missing history, so the copy has to say that rather than merely reporting a number.
        for n in [1, 2, 99] {
            let copy = PopoverDetailStrings.historyRowsDropped(n)
            XCTAssertTrue(copy.contains("dropped"), copy)
            XCTAssertTrue(copy.contains("missing from the charts"), copy)
        }
    }
}
