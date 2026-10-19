import Foundation
import Combine

/// Sprint 4.G (#28): the persistent history store feeding 4.2's graphs. Deliberately boring —
/// JSONL day-files + a long-horizon health file, append-only via FileHandle, crash-tolerant by format.
/// A PASSIVE consumer of the existing classified-sample pipeline (one call site; classifier inputs
/// untouched). All timestamps are UTC epoch seconds; the DISPLAY layer (4.2) converts to local.

// MARK: - models (the read-API contract for 4.2)

/// One charge row / read point. (limit/soc/watts nil → key omitted in JSONL via encodeIfPresent.)
struct ChargePoint: Codable, Equatable, Sendable {
    let ts: Int          // UTC epoch seconds
    let soc: Int?
    let watts: Double?   // signed, 0.1 W
    let onAC: Bool
    let state: String
    let limit: Int?
}

/// The schema-tolerant decoder for raw day lines — the SWEEP H2 pattern (`PauseCapture`), as on
/// `HourlyAggregate` below, and for the same landmine one tier down: with the synthesized `Decodable`,
/// adding one non-optional field makes every line already on disk undecodable, so every raw day still
/// inside retention would fold NOTHING (and, before the three-state raw read, a day mixing old and new
/// lines would fold the new ones and then be pruned with the old ones in it).
///
/// WHAT STAYS REQUIRED: `ts`, `onAC`, `state` — non-optional since the struct was born (`9f59d24`,
/// unchanged since), so every line any version ever appended carries them. The three optionals were
/// always omitted when nil (`encodeIfPresent`). Unknown keys are ignored by `JSONDecoder`. The
/// synthesized `encode(to:)` is kept; the round-trip and frozen-v1 tests in `HistoryAggregateReadTests`
/// are the tripwires.
extension ChargePoint {
    enum CodingKeys: String, CodingKey {
        case ts, soc, watts, onAC, state, limit
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version; absent means this is not a charge row.
        self.ts = try c.decode(Int.self, forKey: .ts)
        self.onAC = try c.decode(Bool.self, forKey: .onAC)
        self.state = try c.decode(String.self, forKey: .state)
        // TOLERANT — every field from here on, and EVERY FIELD ADDED LATER, must be decoded this way.
        self.soc = try c.decodeIfPresent(Int.self, forKey: .soc)
        self.watts = try c.decodeIfPresent(Double.self, forKey: .watts)
        self.limit = try c.decodeIfPresent(Int.self, forKey: .limit)
    }
}

/// Redman "data loss", the raw-tier mirror of `AggregateMonthRead`: how one raw day file READ.
///
/// The old reader returned `[ChargePoint]`, so "no file", "a file this process cannot read" and "a
/// file whose lines partly will not decode" all collapsed into "these are the rows". The fold then read
/// an unreadable day as an EMPTY day (silent), and a partly undecodable day folded its good lines,
/// passed the `dayIsAggregated` gate and was PRUNED — taking the lines that did not decode with it.
enum RawDayRead: Equatable, Sendable {
    /// No file for this day.
    case missing
    /// The file was read. `undecodableLines` counts the non-empty lines that would not decode (a torn
    /// append, a bad byte, a line this build's schema cannot satisfy). Non-zero means the file holds
    /// bytes the rows do not account for, so it must never be pruned as though it were folded.
    case decoded(rows: [ChargePoint], undecodableLines: Int)
    /// A file IS there but could not be stat'ed or read. Not an empty day.
    case unreadable
}

struct HealthPoint: Codable, Equatable, Sendable {
    let ts: Int
    let healthPct: Double?
    let cycles: Int?
    let maxCap_mAh: Int?
}

/// The schema-tolerant decoder for `health.jsonl` lines — the SWEEP H2 pattern (`PauseCapture`), as on
/// `ChargePoint` and `HourlyAggregate`. This file is the long-horizon capacity-fade series (12 months,
/// no aggregate tier below it), so a future non-optional field decoded by the synthesized `Decodable`
/// would make every old row undecodable — and the retention rewrite used to drop undecodable lines.
///
/// WHAT STAYS REQUIRED: `ts` only. It is the one non-optional field since the struct was born
/// (`9f59d24`, unchanged since); the other three were always optional and omitted when nil.
extension HealthPoint {
    enum CodingKeys: String, CodingKey {
        case ts, healthPct, cycles, maxCap_mAh
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version; absent means this is not a health row.
        self.ts = try c.decode(Int.self, forKey: .ts)
        // TOLERANT — every field from here on, and EVERY FIELD ADDED LATER, must be decoded this way.
        self.healthPct = try c.decodeIfPresent(Double.self, forKey: .healthPct)
        self.cycles = try c.decodeIfPresent(Int.self, forKey: .cycles)
        self.maxCap_mAh = try c.decodeIfPresent(Int.self, forKey: .maxCap_mAh)
    }
}

/// Hourly downsample (kept 12 months after the raw day is pruned).
struct HourlyAggregate: Codable, Equatable, Sendable {
    let socMin: Int?
    let socMax: Int?
    let socAvg: Double?
    let wattsAvg: Double?
    let acFraction: Double
    let dominantState: String
    let count: Int
}

/// The schema-tolerant decoder — the SWEEP H2 pattern (`PauseCapture`, PauseResume.swift), applied to
/// the month aggregates for the same reason.
///
/// THE HAZARD. Swift's SYNTHESIZED `Decodable` throws on a missing key; it does not fall back to a
/// default. A month file is ONE dictionary decoded in one go, so the day a later release adds a single
/// non-optional field here, every hour of every month the previous release wrote lacks that key and the
/// whole file stops decoding — on every machine, at the first launch after the upgrade. Before the
/// three-state read below that also meant the next maintenance run wrote one day over the month.
///
/// THE MECHANISM (as `PauseCapture`, and why): a hand-written `init(from:)` in an EXTENSION — the
/// extension keeps the memberwise init every call site uses. It removes the synthesis, so a field
/// added later WITHOUT a default is forced by the compiler into this initializer, beside lines that
/// all use the tolerant pattern; one added with a default compiles untouched and merely never
/// decodes (a lost field, never an unreadable month). Both ways of forgetting fail safe.
///
/// WHAT STAYS REQUIRED: `acFraction`, `dominantState`, `count` — non-optional since the struct was
/// born (`9f59d24`, unchanged since), so every version that ever wrote a month wrote them. An hour
/// without them is not a lenient aggregate, it is unreadable, and `AggregateMonthRead.unreadable` is
/// the honest answer. The four optionals were always omitted when nil (`encodeIfPresent`), so they
/// were always tolerant; they stay so explicitly. Unknown keys (bytes from a LATER release) are
/// ignored by `JSONDecoder` — pinned by `HistoryAggregateReadTests`.
///
/// The synthesized `encode(to:)` is deliberately kept (it cannot drift from the stored properties);
/// the round-trip test is the tripwire for a field that is encoded but not decoded, and the frozen-v1
/// fixture test is the tripwire for a field that old bytes cannot satisfy.
extension HourlyAggregate {
    enum CodingKeys: String, CodingKey {
        case socMin, socMax, socAvg, wattsAvg, acFraction, dominantState, count
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ESSENTIAL — written by every version; absent means this is not an aggregate.
        self.acFraction = try c.decode(Double.self, forKey: .acFraction)
        self.dominantState = try c.decode(String.self, forKey: .dominantState)
        self.count = try c.decode(Int.self, forKey: .count)
        // TOLERANT — every field from here on, and EVERY FIELD ADDED LATER, must be decoded this way.
        self.socMin = try c.decodeIfPresent(Int.self, forKey: .socMin)
        self.socMax = try c.decodeIfPresent(Int.self, forKey: .socMax)
        self.socAvg = try c.decodeIfPresent(Double.self, forKey: .socAvg)
        self.wattsAvg = try c.decodeIfPresent(Double.self, forKey: .wattsAvg)
    }
}

/// Redman ledger "data loss" (verified 2026-09-28): how one month aggregate file READ.
///
/// `[String: HourlyAggregate]` answered two completely different questions with the same `[:]` —
/// *"this month has no file yet"* and *"this month's file will not decode"* — and `aggregate(day:)`
/// then merged one day into that `[:]` and atomically wrote it over the month, whose other days' raw
/// files had already been pruned (7-day raw retention). Up to a month of hourly history, gone in
/// silence. `try? … ?? [:]` made the second answer become the first.
///
/// Same three-state posture as the precedents in the tree: `PauseCaptureLoad` (.none / .capture /
/// .corrupt), `PowerAdapterReadState` (.connected / .noAdapter / .unavailable), `RawCorroboration`,
/// `TemperatureReading`, `BatteryLifetimeReadFailure`. Absence gets its own name so it can never be
/// read as an answer.
enum AggregateMonthRead: Equatable, Sendable {
    /// No file for this month — the LEGITIMATE empty. The first fold creates it.
    case missing
    /// The file decoded (possibly to an empty dictionary — that is still a real answer).
    case decoded([String: HourlyAggregate])
    /// A file IS there but could not be read or decoded (a torn copy, a restored backup, a disk
    /// error, bytes from a schema this build cannot satisfy). It holds days whose raw files are gone,
    /// so it must never be written over: nothing may be merged into it, and the raw day that could not
    /// be folded in must not be pruned.
    case unreadable
}

extension AggregateMonthRead {
    /// The hours to DISPLAY. `.unreadable` shows as no hours — a gap in a chart, never a fact — and
    /// is surfaced separately (`HistoryStore.unreadableAggregateMonths` + a log line). Never fold into
    /// this value: a fold must switch on the state so it can refuse `.unreadable`.
    var hoursForDisplay: [String: HourlyAggregate] {
        if case .decoded(let hours) = self { return hours } else { return [:] }
    }
}

/// The combined sample handed in from the ONE call site (the store stamps the UTC ts itself, so the
/// clock seam controls every timestamp).
struct HistorySample {
    let soc: Int?
    let watts: Double?
    let onAC: Bool
    let state: String
    let limit: Int?
    let healthPct: Double?
    let cycles: Int?
    let maxCap_mAh: Int?
}

// MARK: - UTC formatting + derived values (pure)

enum HistoryFormat {
    /// The one encoder for every JSON object this store writes (raw day lines, health lines, month
    /// aggregates). `.sortedKeys` makes the bytes a function of the value: a plain `JSONEncoder` orders keys
    /// by a hash seeded per process (and was measured ordering the same value two ways within one
    /// process), so the same row could land as different bytes. Readers do not care — the decoders read by
    /// key, and `scripts/capture-ncr-at-full.sh` matches each key with its own regex — so lines already on
    /// disk in hash order and new sorted lines read the same. The output is otherwise the default
    /// (compact, no escaping changes).
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// watts = (Voltage_mV × InstantAmperage_mA)/1e6 = V × mA / 1000, signed, rounded 0.1 W.
    /// (Same formula as the popover's WattageReadout; duplicated here to keep that file frozen.)
    static func watts(voltageVolts: Double?, amperageMilliamps: Int?) -> Double? {
        // B5: the same non-finite-voltage guard `WattageReadout.compact` / `.label` carry (`758330e`).
        // A NaN/±inf volt reading makes `watts` non-finite, `JSONEncoder` throws on it, and the row is
        // lost. A value we cannot compute is a MISSING watts, never a NaN one. (`mA` is an Int and
        // cannot be non-finite, so only the voltage needs it.)
        guard let v = voltageVolts, let mA = amperageMilliamps, v.isFinite else { return nil }
        return ((v * Double(mA) / 1000.0) * 10).rounded() / 10
    }

    static func stateString(_ s: TelemetryChargeState) -> String {
        switch s {
        case .charging:      return "charging"
        case .discharging:   return "discharging"
        case .limitHold:     return "limitHold"
        case .idleInhibit:   return "idleInhibit"
        case .ambiguousHold: return "ambiguousHold"
        case .unknown:       return "unknown"
        }
    }

    // UTC midnight / hour are exact multiples of 86400 / 3600 in epoch seconds (UTC has no DST).
    static func utcDayStart(_ ts: Int) -> Int { ts - (((ts % 86400) + 86400) % 86400) }
    static func utcHourStart(_ ts: Int) -> Int { ts - (((ts % 3600) + 3600) % 3600) }

    private static func utc(_ ts: Int) -> DateComponents {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
    static func dayKey(_ ts: Int) -> String {
        let c = utc(ts); return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func monthKey(_ ts: Int) -> String {
        let c = utc(ts); return String(format: "%04d-%02d", c.year!, c.month!)
    }
}

@MainActor
final class HistoryStore: ObservableObject {
    private let root: URL
    private let now: () -> Int
    /// S2 soft RAM cap (rows). Injected so the re-buffer cap is unit-testable at small N; production
    /// default 10_000 (~7 days at the ≤1/60 s rate, only reached under permanent disk failure).
    private let bufferCap: Int
    private let fm = FileManager.default

    // MARK: - B9 decode memo

    /// **B9.** `series()` is consumed from a COMPUTED SwiftUI view property —
    /// `BatteryPopoverView.d6HistoryCard` reads `history.series(range:)` inline in its `@ViewBuilder`
    /// body — so it re-runs on every body evaluation of the Details page. That same file, 200 lines
    /// lower, says of its SIBLING card: *"this page re-renders on every published telemetry change"*,
    /// and for that exact reason `healthSeries()` was moved into a `.task(id:)`. `d6HistoryCard` never
    /// got the same treatment, and its `now` is recomputed per render, so the request itself changes
    /// every second — a memo keyed on the RANGE would miss almost every time.
    ///
    /// Measured on the owner's machine (optimised build, warm page cache): a 24 h `series()` spans two
    /// day-files, 1,376 rows, and costs **3.8 ms of main-actor JSON decoding per call**; re-filtering
    /// rows that are already decoded costs **0.028 ms**. Per §7.6 the multiplier is not the problem —
    /// the call frequency is, and SwiftUI does not let a caller bound it. So the fix at THIS layer is
    /// to decode a file once per VERSION OF THAT FILE instead of once per caller: the cost stops
    /// scaling with render count and becomes one `stat` (µs) plus a filter.
    ///
    /// The memo key is the file's `(size, modificationDate)`, so an edit by anything at all — this
    /// store, a test, a person with a text editor — invalidates it. Belt AND braces: every write path
    /// in this store also drops the entry explicitly *before* it writes, so correctness never rests on
    /// timestamp granularity or on this type being the only writer.
    ///
    /// **Deliberately NOT memoised: `health.jsonl`.** It is by far the largest read here (18,079 rows /
    /// 1.2 MB / 40 ms on the owner's machine) but its two callers are both cold-or-rare: `pruneHealth`
    /// reads it once at launch (a cold read no cache can help) and `healthSeries()` is already
    /// `.task(id:)`-gated to appearance + range change. Memoising it would trade 40 ms of
    /// once-per-session work for megabytes resident for the whole session — the wrong trade for a
    /// menu-bar app.
    private struct FileStamp: Equatable {
        let size: Int
        let mtime: TimeInterval
    }
    private struct Memo<T> {
        let stamp: FileStamp
        let value: T
    }
    private var chargeMemo: [String: Memo<RawDayRead>] = [:]
    private var aggMemo: [String: Memo<AggregateMonthRead>] = [:]
    /// Memo bound (per memo: raw days, and months). Sized for the KEPT case, not the steady state: a
    /// month whose aggregate will not read keeps up to 31 raw days on disk beside the ~9 recent ones,
    /// and the lifetime read (`lifetimeRows`, re-run on every Now/Health recompute) walks every one of
    /// them. At 16 the memo cleared itself mid-walk and re-decoded every file on every call (reported
    /// ~340 ms per recompute with ~40 files); 64 holds 31 + 9 with margin, and the month memo's ≤ 14
    /// files. A range wider than this decodes each day once per call — what happened before the memo
    /// existed, so the pathological case is never WORSE than the status quo, just no better.
    static let memoCap = 64

    /// Full file decodes performed this session. A cheap diagnostic (and the memo's test oracle):
    /// with the memo working this stays flat across repeated reads of an unchanged file.
    private(set) var fileDecodes = 0
    /// History files (by file name) that could not even be stat'ed or READ (access, not bytes) and that
    /// have been logged this session — that failure is deliberately not memoised, so the log needs its
    /// own once-only gate (the read paths run inside SwiftUI bodies).
    private var unreadableFilesLogged: Set<String> = []

    // recording discipline
    private var buffer: [ChargePoint] = []
    private var lastCharge: ChargePoint?
    private var lastFlushAt: Int?
    private var healthBuffer: [HealthPoint] = []
    private var lastHealth: HealthPoint?
    private var lastHealthDayKey: String?

    static let rateBound = 60          // ≤ 1 periodic row / 60 s
    static let flushRows = 10
    /// B-arc B5: 300 s, not 60 s. The buffered tail is already bounded on both normal exits (the sleep and
    /// quit flush seams), so this only widens the CRASH-loss window for best-effort analytics rows from
    /// ≤1 min to ≤5 min — in exchange for 4/5 fewer standing disk writes. `flushRows` still caps the buffer.
    static let flushSeconds = 300
    static let rawRetentionDays = 7
    static let aggRetentionMonths = 12
    /// A raw day KEPT for bytes it could not fold (unreadable, or with undecodable lines) is released
    /// at the aggregate horizon — the same month≈31d arithmetic as `pruneAggregates`.
    static let keptRawHorizonDays = aggRetentionMonths * 31
    /// The oldest a raw day on disk can be, and so how far back a lifetime read walks
    /// (`lifetimeRows`). A raw day kept because its MONTH will not read is not released at
    /// `keptRawHorizonDays`: it is held while that month's file exists, and `pruneAggregates` removes a
    /// month only once its LAST day is past the horizon — so the month's first day can be up to 31 days
    /// older still.
    static let maxRawAgeDays = keptRawHorizonDays + 31

    /// A6: health rows use a HYSTERESIS DEADBAND, not a quantization grid. `BatteryMonitor
    /// .refreshDiagnostics` feeds this store a 5-SAMPLE ROLLING MEAN of `AppleRawMaxCapacity /
    /// DesignCapacity`, so the value never settles on a level — it drifts continuously and re-crosses
    /// whatever grid you pick. That is why 4.G's 0.1% grid (`a9f09d3`, which claimed the file "returns
    /// to ~KB-forever") did not hold: measured on the owner's machine it wrote 18,029 rows / 1.2 MB in
    /// 88 days = 204 rows/day lifetime, 325/day over the last week, because the smoothed value walks a
    /// 6.5%-wide band (raw FCC 5198…5639 mAh). A deadband compares against the LAST RECORDED value, so
    /// bounded noise can never trigger a write no matter where in the band the signal happens to sit.
    static let healthDeadbandPct = 1.0
    /// …and even a genuine move is a months-scale event, so cap the health series at one row an hour.
    /// (Cycle ticks and the guaranteed daily row are exempt — they are intrinsically rare and are what
    /// makes this a usable capacity-fade series.)
    static let healthRateBound = 3600
    /// A6: health.jsonl is no longer "never pruned". Same 12-month horizon as the aggregates — it IS
    /// the long-horizon tier (there is no aggregate tier below it), so it gets the aggregates' bound.
    static let healthRetentionMonths = 12

    /// First-record date (Settings "Recording history since …"). Persisted as a marker file.
    @Published private(set) var recordingSince: Date?
    /// Final review F8: the `.started` marker EXISTS but could not be read or parsed. `recordingSince`
    /// is then nil for want of a readable date — not because recording never started — and the marker is
    /// never written over (`markRecordingSince`). NOT `@Published`: no screen; NSLog'd at launch.
    private(set) var recordingSinceUnreadable = false

    /// S2/S3: a level signal — true when a maintenance run left a raw day uncompacted: an aggregate
    /// could not be WRITTEN (`aggregateWriteFailed`), a month would not READ (`unreadableAggregateMonths`)
    /// or a raw day would not READ (`unreadableRawDays`). Set on the MainActor (this class is @MainActor,
    /// like recordingSince); clears to false when a run completes clean. Not shown as such: the Health
    /// note (spec 30 §16 "32 · Health · history note") reads the three named causes instead, because
    /// only one of them may honestly be called "couldn't be saved".
    @Published private(set) var maintenanceStalled: Bool = false

    /// Spec 30 §16 "32 · Health · history note": the last maintenance run could not WRITE a month
    /// aggregate (disk) — the one stall cause the Health note calls "couldn't be saved". The day's raw
    /// file is kept until the write lands. A level signal, recomputed every run.
    @Published private(set) var aggregateWriteFailed: Bool = false

    /// Review fix 4: the last flush could not APPEND a raw charge or health row (disk full, folder
    /// unwritable). Those rows are kept only in RAM — capped at `bufferCap`, oldest dropped first, and
    /// lost on quit — so the Health note says "new readings may be lost". Raised by a failed `flush` /
    /// `flushHealth` append; cleared by the next `flush()` in which everything landed.
    @Published private(set) var rawWriteFailed: Bool = false

    /// Review fix 6: the history folder could not be LISTED at the last check, so which files are
    /// unreadable is unknown — the Health note says "History couldn't be read" (no month), and the named
    /// sets are left as they were rather than cleared to "nothing unreadable". Maintenance acts on nothing
    /// a failed listing would have told it (no fold, no prune). Set by `refreshUnreadableHistory()`.
    @Published private(set) var historyFolderUnreadable: Bool = false

    /// Spec 30 §16 "32 · Health · history note": the raw day keys (`"2025-06-03"`) that could not be READ
    /// (stat or open) at the last check. Each is kept as is (not folded, not pruned) until it reads or
    /// ages past `keptRawHorizonDays`. A level signal, recomputed by `refreshUnreadableHistory()` (every
    /// maintenance run, and when the Health page appears). Days inside raw retention are not visited by
    /// maintenance, so they are not named here.
    @Published private(set) var unreadableRawDays: Set<String> = []

    /// B5: rows the ENCODER rejected and that were therefore dropped. `encode` used to fall back to a
    /// literal `"{}"`, which the writer landed and COUNTED AS SUCCESS — the reader then discarded that
    /// line as junk, so the row became a silent history gap. A row that cannot be encoded is now
    /// dropped honestly and counted here. Unlike a write failure (transient → re-buffered and retried),
    /// an encode failure is deterministic: the same row will never encode, so retrying it would pin the
    /// buffer forever. Monotonic within a session; expected to stay 0 (the `HistoryFormat.watts` guard
    /// is the first line of defence — this is the last).
    @Published private(set) var unencodableRowsDropped: Int = 0

    /// Redman "data loss": the month keys (`"2025-06"`) whose aggregate file the last maintenance run
    /// found UNREADABLE. A fold into one is refused: its bytes are left untouched and the raw day files
    /// for it are kept (not pruned), so nothing is lost — but those days are not being compacted (which
    /// raises `maintenanceStalled`), and the month's hours cannot be shown until the file is readable or
    /// removed. Spec 30 §16 "32 · Health · history note": EVERY unreadable month file still on disk after
    /// the prune is named, not only one a fold was refused for — a month nothing is folding into hides
    /// its hours from the Health figures just the same (it does not raise the stall: nothing is kept
    /// uncompacted for it). A level signal: recomputed every run, so it clears by itself once the file
    /// is repaired, moved aside or ages out of retention.
    /// Set only by `refreshUnreadableHistory()` (every maintenance run, and when the Health page appears)
    /// — never from the display read path, which runs inside SwiftUI bodies.
    @Published private(set) var unreadableAggregateMonths: Set<String> = []

    init(root: URL, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }, bufferCap: Int = 10_000) {
        self.root = root
        self.now = now
        self.bufferCap = bufferCap
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Final review F8: three-state. A marker that is there but will not read or parse is NOT "never
        // recorded" — the old `try?` made it so, and the first ingest then wrote today over the user's
        // real start date.
        if fm.fileExists(atPath: sinceURL.path) {
            if let ts = (try? String(contentsOf: sinceURL, encoding: .utf8))
                .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                recordingSince = Date(timeIntervalSince1970: TimeInterval(ts))
            } else {
                recordingSinceUnreadable = true
                NSLog("battery_app: history marker %@ exists but will not read as a timestamp — the "
                      + "recording-since date is unknown and the marker is kept as-is.", sinceURL.path)
            }
        }
    }

    // MARK: - the ONE ingest path (charge + health)

    func ingest(_ s: HistorySample) {
        let ts = now()
        markRecordingSince(ts)
        recordCharge(ts, s)
        recordHealth(ts, s)
        maybeFlush(ts)
    }

    private func recordCharge(_ ts: Int, _ s: HistorySample) {
        let row = ChargePoint(ts: ts, soc: s.soc, watts: s.watts, onAC: s.onAC, state: s.state, limit: s.limit)
        // Immediate transition rows (state / onAC / SoC step) ride the 4.D events; otherwise ≤1/60 s.
        let transition = lastCharge == nil
            || row.state != lastCharge!.state
            || row.onAC != lastCharge!.onAC
            || row.soc != lastCharge!.soc
        let elapsed = ts - (lastCharge?.ts ?? Int.min / 2)
        guard transition || elapsed >= Self.rateBound else { return }
        buffer.append(row)
        lastCharge = row
        if lastFlushAt == nil { lastFlushAt = ts }
    }

    private func recordHealth(_ ts: Int, _ s: HistorySample) {
        // Nothing to record until diagnostics have populated at least one health field (avoids a
        // degenerate empty row from the very first snapshot, before the gauge is read).
        guard s.healthPct != nil || s.cycles != nil || s.maxCap_mAh != nil else { return }
        // The STORED value stays at 0.1% (4.G) — that is a display precision, not the change-detect.
        let roundedHealth = s.healthPct.map { ($0 * 10).rounded() / 10 }
        let dayKey = HistoryFormat.dayKey(ts)
        // A6: a "real move" is a DEADBAND crossing measured against the last RECORDED row, further
        // rate-bounded. `maxCap_mAh` is deliberately NOT in the change-detect (it never was) — it is the
        // jittering field and is carried only as evidence alongside whatever row a real signal earns.
        var healthMoved = false
        if let last = lastHealth {
            switch (roundedHealth, last.healthPct) {
            case let (new?, old?):
                healthMoved = abs(new - old) >= Self.healthDeadbandPct
                    && (ts - last.ts) >= Self.healthRateBound
            case (nil, nil):
                healthMoved = false
            default:
                healthMoved = true          // the field appeared or disappeared — a real state change
            }
        }
        let changed = lastHealth == nil
            || healthMoved
            || s.cycles != lastHealth!.cycles
            || dayKey != lastHealthDayKey
        guard changed else { return }
        let h = HealthPoint(ts: ts, healthPct: roundedHealth, cycles: s.cycles, maxCap_mAh: s.maxCap_mAh)
        // A6: BUFFERED like the charge rows — was one FileHandle open/seek/write/close PER ROW, on the
        // MainActor, ~204×/day. The dedup state advances on BUFFERING, not on a landed write, because
        // S2's retry is now the buffer itself: a failed flush re-buffers the row instead of dropping it.
        healthBuffer.append(h)
        lastHealth = h
        lastHealthDayKey = dayKey
        if lastFlushAt == nil { lastFlushAt = ts }
    }

    private func maybeFlush(_ ts: Int) {
        guard !buffer.isEmpty || !healthBuffer.isEmpty else { return }
        if buffer.count >= Self.flushRows || healthBuffer.count >= Self.flushRows
            || (ts - (lastFlushAt ?? ts)) >= Self.flushSeconds { flush() }
    }

    /// Flush the buffer — grouped by UTC day so a midnight-crossing buffer lands in both files (rows
    /// land by UTC, never duplicated/lost). Seam: also called on quit/sleep.
    func flush() {
        guard !buffer.isEmpty || !healthBuffer.isEmpty else { return }
        let groups = Dictionary(grouping: buffer, by: { HistoryFormat.dayKey($0.ts) })
        var failed: [ChargePoint] = []
        var chargeLanded = true
        for (day, rows) in groups {
            let writable = encodable(rows.sorted { $0.ts < $1.ts })
            if !append(writable.map(\.line), to: chargeURL(day)) {
                // S2: a group that didn't persist stays buffered (not dropped). B5: only the rows that
                // CAN encode are re-buffered — an unencodable row would never drain.
                failed.append(contentsOf: writable.map(\.row))
                chargeLanded = false
            }
        }
        buffer = failed                            // only un-persisted groups survive; the rest drained
        // S2 soft RAM cap: under permanent disk failure, bound the re-buffered rows to `bufferCap`, dropping
        // the OLDEST overflow (recent data preserved, loss bounded; maintenanceStalled makes the underlying
        // disk failure visible). suffix = newest for a single-day flush (the common case); a multi-day failing
        // flush re-buffers in group order, so "newest" is approximate across days.
        if buffer.count > bufferCap { buffer = Array(buffer.suffix(bufferCap)) }
        let healthLanded = flushHealth()
        let failedNow = !(chargeLanded && healthLanded)
        if rawWriteFailed != failedNow { rawWriteFailed = failedNow }
        lastFlushAt = now()
    }

    /// A6: drain the buffered health rows in ONE append. Same S2 contract as the charge flush — a
    /// failed append re-buffers rather than drops, and the re-buffer is bounded by `bufferCap`.
    /// Returns whether the buffered rows landed (true when there was nothing to write).
    @discardableResult
    private func flushHealth() -> Bool {
        guard !healthBuffer.isEmpty else { return true }
        let writable = encodable(healthBuffer.sorted { $0.ts < $1.ts })
        if append(writable.map(\.line), to: healthURL) {
            healthBuffer = []
            return true
        } else {
            healthBuffer = writable.map(\.row)      // B5: unencodable rows are not retried
            if healthBuffer.count > bufferCap { healthBuffer = Array(healthBuffer.suffix(bufferCap)) }
            return false
        }
    }

    // MARK: - read API (for 4.2 — stitches raw + aggregates transparently)

    func series(range: ClosedRange<Int>) -> [ChargePoint] {
        var out: [ChargePoint] = []
        var dayStart = HistoryFormat.utcDayStart(range.lowerBound)
        while dayStart <= range.upperBound {
            let day = HistoryFormat.dayKey(dayStart)
            let raw = chargeURL(day)
            if fm.fileExists(atPath: raw.path) {
                // B9: decoded at most once per version of this file, however many times the Details
                // page re-renders. The existence check stays the branch condition (an existing but
                // EMPTY day must not fall through to the aggregate tier — unchanged semantics).
                out += chargeRows(day: day).filter { range.contains($0.ts) }
            } else {
                // Tier fallback: synthesize hourly points from the month aggregate.
                let agg = readAggregate(HistoryFormat.monthKey(dayStart))
                for (key, a) in agg {
                    guard let hourTs = Int(key), HistoryFormat.utcDayStart(hourTs) == dayStart,
                          range.contains(hourTs) else { continue }
                    out.append(ChargePoint(ts: hourTs, soc: a.socAvg.map { Int($0.rounded()) },
                                           watts: a.wattsAvg, onAC: a.acFraction >= 0.5,
                                           state: a.dominantState, limit: nil))
                }
            }
            dayStart += 86400
        }
        return out.sorted { $0.ts < $1.ts }
    }

    func healthSeries() -> [HealthPoint] {
        // Per-line from the bytes (one bad UTF-8 sequence costs one line, not the series). Display only.
        guard fm.fileExists(atPath: healthURL.path) else { return [] }
        let data: Data
        do { data = try Data(contentsOf: healthURL) } catch {
            logUnreadableOnce(healthURL, "cannot be read (\(error))")   // shown as no data, not as "no history"
            return []
        }
        fileDecodes += 1
        return decodeLines(data, as: HealthPoint.self).rows.sorted { $0.ts < $1.ts }
    }

    // MARK: - daily maintenance (aggregate THEN delete — the data-loss guard, sec 3)

    func runMaintenance() {
        let todayStart = HistoryFormat.utcDayStart(now())
        var allAggregatesWritten = true
        var writeFailed = false
        var unreadable: [String: Int] = [:]                           // month key → raw days kept for it
        // Review fix 6: a folder that cannot be listed is NOT "no raw days": nothing is folded or pruned on
        // the strength of a failed listing, and the stall / write signals keep their last known values.
        // The health prune below the fold steps does not depend on the listing and still runs.
        guard let rawFiles = rawDayFiles() else {
            NSLog("battery_app: history folder %@ cannot be listed — maintenance skipped (nothing folded or "
                  + "pruned).", root.path)
            refreshUnreadableHistory()                                // raises historyFolderUnreadable
            pruneHealth(todayStart: todayStart)
            return
        }
        for url in rawFiles {
            guard let day = dayKey(fromCharge: url.lastPathComponent) else { continue }
            let dayStart = HistoryFormat.utcDayStart(epoch(ofDay: day))
            let ageDays = (todayStart - dayStart) / 86400
            guard ageDays > Self.rawRetentionDays else { continue }   // keep 7 days
            // A day KEPT for bytes it could not fold is still bounded: once it is older than the
            // aggregate horizon its folded hours are pruned anyway, so keeping its raw any longer would
            // make one torn line the only unbounded thing in this store.
            let pastAggregateHorizon = ageDays > Self.keptRawHorizonDays
            switch fold(day: day) {                                   // 1) durable aggregate (atomic)
            case .folded, .nothingToFold:
                break
            case .writeFailed:
                allAggregatesWritten = false
                writeFailed = true
            case .monthUnreadable(let month):
                // Redman "data loss": the fold was REFUSED, so this raw file is the only copy of the
                // day. Keep it — never fall through to the prune, whatever `dayIsAggregated` says.
                allAggregatesWritten = false
                unreadable[month, default: 0] += 1
                continue
            case .rawUnreadable:
                // The day could not be READ, so nothing about it is known — not even that it is empty.
                // Kept, and a stall: this raw day is not being compacted.
                if !pastAggregateHorizon {
                    allAggregatesWritten = false
                    NSLog("battery_app: history raw day %@ cannot be read — NOT folded and NOT pruned.", day)
                    continue
                }
                NSLog("battery_app: history raw day %@ cannot be read and is past the %d-day aggregate "
                      + "horizon — released by retention.", day, Self.keptRawHorizonDays)
                removeRawDay(url)
                continue
            case .foldedPartly(let bad):
                // Everything that decoded is in the month; the file holds `bad` line(s) that did not.
                // Kept so those bytes survive (a later build, or a person, may read them). NOT a stall:
                // the day IS compacted for every row this build can see, and one torn line from one
                // power loss must not hold the stall signal up for a year.
                if !pastAggregateHorizon {
                    NSLog("battery_app: history raw day %@ has %d undecodable line(s) — folded the rest, "
                          + "kept the file un-pruned (released after %d days).", day, bad, Self.keptRawHorizonDays)
                    continue
                }
                removeRawDay(url)
                continue
            }
            // 2) ONLY THEN delete raw. The gate is now two-sided: the day's hours are in the month AND the
            // raw file fully decoded — a file holding bytes the fold never saw is never deleted here.
            if rawFullyDecoded(day) && dayIsAggregated(day) { removeRawDay(url) }
        }
        for (month, days) in unreadable.sorted(by: { $0.key < $1.key }) {
            NSLog("battery_app: history month %@ is unreadable — NOT folded into and NOT overwritten; "
                  + "kept %d raw day file(s) for it un-pruned. Repair or move aside %@ to resume compaction.",
                  month, days, aggURL(month).path)
        }
        pruneAggregates(olderThanMonths: Self.aggRetentionMonths, todayStart: todayStart)
        // S3: level signal — true if any aggregate couldn't be written this run (chronic disk failure → the
        // raw can't be pruned and would grow unbounded). Clears to false when a run completes clean (recovered).
        // A fold refused over an unreadable month counts: a raw day is being kept, uncompacted, either way.
        maintenanceStalled = !allAggregatesWritten
        if aggregateWriteFailed != writeFailed { aggregateWriteFailed = writeFailed }
        // The read-side signals, from what is on disk AFTER the prune — never seeded from this run's
        // refused folds: the prune above may have deleted that month file in this same run, and a
        // deleted month must not be named.
        refreshUnreadableHistory()
        // A6: health.jsonl is bounded too now (it was "NEVER pruned" — unbounded by design).
        // FENCE ARGUMENT (4.G declined compaction to keep this job frozen): the frozen invariant here is
        // the aggregate-THEN-delete data-loss guard — an aggregate must land before its raw day is
        // removed. Health has no aggregate tier, so there is no gating to break. This step is a PURE
        // APPEND after the existing logic: it runs after `maintenanceStalled` is computed, reads and
        // writes only health.jsonl, touches no state the raw/aggregate steps use, and cannot change
        // their outcome. It also deliberately does NOT feed the stall signal, whose documented meaning
        // stays "an aggregate could not be written".
        pruneHealth(todayStart: todayStart)
    }

    /// Review fix 3: re-derive `unreadableAggregateMonths` and `unreadableRawDays` from the files on disk
    /// — READS ONLY: nothing is written, folded or pruned, and no maintenance runs. Called at the end of
    /// every `runMaintenance()` and when the Health page appears, so a file repaired (or broken) between
    /// the daily runs is named or un-named the next time the page that shows the note is opened. Each read
    /// is memoised per file version, so on an unchanged folder this is a listing and a stat per file.
    ///
    /// It names exactly what maintenance acts on: a month file is named only while maintenance would keep
    /// it (its last day inside the aggregate horizon — `pruneAggregates` removes the rest, unread), and a
    /// raw day only once it is past raw retention (maintenance does not visit younger days) and not yet
    /// past `keptRawHorizonDays` (where an unreadable day is released).
    func refreshUnreadableHistory() {
        let todayStart = HistoryFormat.utcDayStart(now())
        // Review fix 6: an unlistable folder is unknown, not empty — named as such, and the sets keep
        // their last known values.
        guard let aggs = aggFiles(), let raws = rawDayFiles() else {
            if !historyFolderUnreadable { historyFolderUnreadable = true }
            return
        }
        if historyFolderUnreadable { historyFolderUnreadable = false }
        var months: Set<String> = []
        for url in aggs {
            guard let mk = monthKey(fromAgg: url.lastPathComponent),
                  !monthIsPastAggregateHorizon(mk, todayStart: todayStart) else { continue }
            if readAggregateMonth(mk) == .unreadable { months.insert(mk) }
        }
        var days: Set<String> = []
        for url in raws {
            guard let day = dayKey(fromCharge: url.lastPathComponent) else { continue }
            let ageDays = (todayStart - HistoryFormat.utcDayStart(epoch(ofDay: day))) / 86400
            guard ageDays > Self.rawRetentionDays, ageDays <= Self.keptRawHorizonDays else { continue }
            if readRawDay(day) == .unreadable { days.insert(day) }
        }
        if unreadableAggregateMonths != months { unreadableAggregateMonths = months }
        if unreadableRawDays != days { unreadableRawDays = days }
    }

    /// A6: bound health.jsonl at the aggregates' 12-month horizon. A straight age filter rewritten
    /// ATOMICALLY (temp + rename), so a kill can never leave the file truncated — the same guarantee
    /// `writeAggregate` gives. Writes NOTHING when no row is old enough to drop, so on a young file
    /// (and on every run in the first year) this is a read and an early return, not a rewrite.
    /// Returns whether the file is within the bound afterwards.
    ///
    /// **B9, re-filed (2026-09-08).** The audit's original attribution — *"history I/O blocks launch,
    /// including `runMaintenance()`"* — named the wrong cause. Aggregation is near-free in steady state:
    /// 7-day raw retention leaves zero eligible files on a machine that has been running for months. The
    /// launch cost was HERE, and it was worse than slow, it was **pointless**: 18,084 rows / 1.2 MB / 40 ms
    /// of main-actor JSON decoding, every launch, *to discover there was nothing to do* — because on a
    /// 12-month horizon nothing is old enough to drop and will not be for the best part of a year.
    ///
    /// So the read is now EARNED, not assumed. Health rows are appended in time order (each batch is
    /// sorted in `flushHealth`, and batches land in wall-clock order), so the file's FIRST line is its
    /// oldest row — and one bounded read of that line answers "is there anything past the cutoff?" for
    /// microseconds instead of 40 ms. The full decode still happens the moment the answer is yes.
    ///
    /// Chosen over *"make `runMaintenance()` async"* on three grounds, recorded so it is not re-litigated:
    /// async RELOCATES the 40 ms rather than removing it (this is an energy audit — the cheapest joule is
    /// the one not spent); getting file I/O off a `@MainActor` store whose `@Published` state the same
    /// method writes is a real concurrency refactor, not a keyword, and Swift 6 gives no `@unchecked`
    /// shortcut here; and neither of those addresses the actual defect, which is that the method reads
    /// a megabyte to learn it has no work.
    ///
    /// The fast path can only ever SKIP, never prune, so its failure mode is bounded: if a backwards
    /// clock step ever left an older row behind a younger first line, the skip lasts exactly until that
    /// first line itself ages past the cutoff, at which point the full read prunes both. An unreadable or
    /// undecodable first line is not evidence of anything and falls through to the full read.
    @discardableResult
    func pruneHealth(todayStart: Int) -> Bool {
        // Never prune around rows that are only in RAM. A failure here raises the note's signal; only a
        // full `flush()` clears it (the charge buffer may still be failing).
        if !flushHealth(), !rawWriteFailed { rawWriteFailed = true }
        guard fm.fileExists(atPath: healthURL.path) else { return true }
        let cutoff = todayStart - Self.healthRetentionMonths * 31 * 86400   // month≈31d, as pruneAggregates
        if let oldest = oldestHealthTimestamp(), oldest >= cutoff { return true }  // B9: nothing to drop
        // Redman "data loss" (health mirror): the rewrite is a LINE FILTER over the bytes, not a
        // decode-and-re-encode. The ONLY lines it removes are rows that decoded AND are past the cutoff;
        // every other line — kept rows, and lines that would not decode (a torn append, a bad byte, a
        // schema this build cannot satisfy) — is passed through byte for byte. The old rewrite went
        // through `readLines` + `encodable`, so it deleted every undecodable line ("a repair") and
        // stripped any field this build does not know from every row it kept.
        // Chosen over refusing to rewrite when a bad line exists: refusal would stop retention for good
        // on the first torn line (the file grows forever); the pass-through loses nothing and still
        // bounds the file. Cost: an undecodable FIRST line defeats the B9 fast path (it falls through to
        // the full read every run) — bounded, and only for a file that already holds a bad line.
        let data: Data
        do { data = try Data(contentsOf: healthURL) } catch {
            logUnreadableOnce(healthURL, "cannot be read (\(error))")
            return false                                // NEVER rewritten; not known to be within bound
        }
        fileDecodes += 1
        let dec = JSONDecoder()
        var body = Data()
        var dropped = 0, undecodable = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let row = try? dec.decode(HealthPoint.self, from: Data(line)) {
                if row.ts < cutoff { dropped += 1; continue }
            } else {
                undecodable += 1
            }
            body.append(contentsOf: line)
            body.append(0x0A)
        }
        guard dropped > 0 else { return true }                              // nothing to drop → no write
        if undecodable > 0 {
            NSLog("battery_app: health history prune kept %d undecodable line(s) verbatim in %@ "
                  + "(dropped %d row(s) past retention).", undecodable, healthURL.path, dropped)
        }
        do { try body.write(to: healthURL, options: .atomic); return true }
        catch { return false }                          // left intact; retried on the next run
    }

    /// B9: the timestamp of the OLDEST health row, read from the file's first line only — one open and
    /// one bounded read instead of decoding the whole file. nil when the answer is not knowable cheaply
    /// (no first line within the window, unreadable, or undecodable), which the caller must treat as
    /// "look properly", never as "nothing to do".
    ///
    /// The window is generous by two orders of magnitude: a `HealthPoint` line is ~66 bytes and this
    /// reads up to 4 KB, so a first line long enough to defeat it is itself corruption — and corruption
    /// correctly returns nil and pays for the full read that repairs the file.
    private func oldestHealthTimestamp() -> Int? {
        guard let h = try? FileHandle(forReadingFrom: healthURL) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), let newline = head.firstIndex(of: 0x0A) else { return nil }
        return (try? JSONDecoder().decode(HealthPoint.self, from: head[head.startIndex..<newline]))?.ts
    }

    /// Build hourly aggregates for one raw day and merge them into the month file (atomic write —
    /// the file is never partial, so a kill leaves the raw intact + re-runs are idempotent).
    /// Returns whether the day's DECODABLE hours are durably in the month afterwards; `false` when the
    /// write failed, when the month is unreadable and the fold was refused, and when the raw day itself
    /// could not be read (see `fold(day:)`). A partly undecodable day returns `true` — its readable hours
    /// landed — but that is not permission to prune it; only `runMaintenance`'s gate decides that.
    @discardableResult
    func aggregate(day: String) -> Bool {
        switch fold(day: day) {
        case .folded, .nothingToFold, .foldedPartly: return true
        case .writeFailed, .monthUnreadable, .rawUnreadable: return false
        }
    }

    private func removeRawDay(_ url: URL) {
        invalidateMemo(for: url)                                      // B9: the memo never outlives the file
        try? fm.removeItem(at: url)
    }

    /// The raw file read, and every non-empty line in it decoded. (Memoised, so this is a stat.)
    private func rawFullyDecoded(_ day: String) -> Bool {
        if case .decoded(_, 0) = readRawDay(day) { return true }
        return false
    }

    private enum FoldOutcome: Equatable {
        case folded
        /// The rows that decoded were folded (possibly none), but the file has undecodable line(s):
        /// the raw must be kept.
        case foldedPartly(undecodableLines: Int)
        /// The raw file exists but could not be stat'ed or read: nothing was folded, the raw is kept.
        case rawUnreadable
        /// The raw day has no rows — S3: not a failure (must not trip the stall).
        case nothingToFold
        /// The merged month could not be written (disk) — S3: the raw is kept by the delete gating.
        case writeFailed
        /// The month file exists but will not read/decode, so the fold was REFUSED and nothing written.
        case monthUnreadable(String)
    }

    /// The fold. Merging is only ever done into a month that READ: `.missing` starts a fresh month,
    /// `.decoded` is merged into, and `.unreadable` is refused outright — merging one day into the `[:]`
    /// it used to read as, and atomically writing that over the month, is the data-loss defect.
    ///
    /// The raw side is three-state too. `.unreadable` folds nothing. `.decoded` with undecodable lines
    /// FOLDS ITS GOOD LINES (rather than refusing) — the fold is idempotent and keyed by hour, so it costs
    /// nothing to redo, it keeps the aggregate-only readers (limit-hold hours, weekly medians) complete,
    /// and a later build that can read the bad lines simply re-folds those hours whole. Refusing would
    /// protect nothing extra: the file is kept either way.
    private func fold(day: String) -> FoldOutcome {
        let rows: [ChargePoint]
        let undecodable: Int
        switch readRawDay(day) {
        case .missing:                                  return .nothingToFold   // vanished since the listing
        case .unreadable:                               return .rawUnreadable
        case .decoded(let r, let bad):                  rows = r; undecodable = bad
        }
        guard !rows.isEmpty else {
            return undecodable > 0 ? .foldedPartly(undecodableLines: undecodable) : .nothingToFold
        }
        let monthKey = HistoryFormat.monthKey(epoch(ofDay: day))
        var month: [String: HourlyAggregate]
        switch readAggregateMonth(monthKey) {
        case .missing:             month = [:]
        case .decoded(let hours):  month = hours
        case .unreadable:          return .monthUnreadable(monthKey)
        }
        let byHour = Dictionary(grouping: rows, by: { HistoryFormat.utcHourStart($0.ts) })
        for (hour, hrRows) in byHour { month[String(hour)] = Self.hourly(hrRows) }
        guard writeAggregate(month, monthKey: monthKey) else { return .writeFailed }
        return undecodable > 0 ? .foldedPartly(undecodableLines: undecodable) : .folded
    }

    static func hourly(_ rows: [ChargePoint]) -> HourlyAggregate {
        let socs = rows.compactMap { $0.soc }
        let watts = rows.compactMap { $0.watts }
        let acCount = rows.filter { $0.onAC }.count
        let states = Dictionary(grouping: rows, by: { $0.state }).mapValues { $0.count }
        let dominant = states.max { a, b in a.value < b.value }?.key ?? "unknown"
        return HourlyAggregate(
            socMin: socs.min(), socMax: socs.max(),
            socAvg: socs.isEmpty ? nil : Double(socs.reduce(0, +)) / Double(socs.count),
            wattsAvg: watts.isEmpty ? nil : (watts.reduce(0, +) / Double(watts.count)),
            acFraction: rows.isEmpty ? 0 : Double(acCount) / Double(rows.count),
            dominantState: dominant, count: rows.count)
    }

    private func dayIsAggregated(_ day: String) -> Bool {
        let agg = readAggregate(HistoryFormat.monthKey(epoch(ofDay: day)))
        let dayStart = HistoryFormat.utcDayStart(epoch(ofDay: day))
        return agg.keys.contains { Int($0).map { HistoryFormat.utcDayStart($0) == dayStart } ?? false }
    }

    private func pruneAggregates(olderThanMonths months: Int, todayStart: Int) {
        guard let files = aggFiles() else { return }                  // never prune on a failed listing
        for url in files {
            guard let mk = monthKey(fromAgg: url.lastPathComponent) else { continue }
            if monthIsPastAggregateHorizon(mk, todayStart: todayStart, months: months) { try? fm.removeItem(at: url) }
        }
    }

    /// A month is prunable once its LAST day is older than the cutoff (generous month≈31d; keeps ≥12
    /// months). A malformed key reads as epoch 0 — past it.
    private func monthIsPastAggregateHorizon(_ mk: String, todayStart: Int,
                                             months: Int = HistoryStore.aggRetentionMonths) -> Bool {
        epoch(ofMonthEnd: mk) < todayStart - months * 31 * 86400
    }

    // MARK: - files

    private var sinceURL: URL { root.appendingPathComponent(".started") }
    private var healthURL: URL { root.appendingPathComponent("health.jsonl") }
    private func chargeURL(_ day: String) -> URL { root.appendingPathComponent("charge-\(day).jsonl") }
    private func aggURL(_ month: String) -> URL { root.appendingPathComponent("agg-\(month).json") }

    private func markRecordingSince(_ ts: Int) {
        // F8: never write over a marker that exists but could not be read — it may hold the real date.
        guard recordingSince == nil, !recordingSinceUnreadable else { return }
        try? String(ts).write(to: sinceURL, atomically: true, encoding: .utf8)
        recordingSince = Date(timeIntervalSince1970: TimeInterval(ts))
    }

    /// The raw day files, or nil when the folder cannot be listed (unknown — never "none").
    private func rawDayFiles() -> [URL]? {
        (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("charge-") && $0.pathExtension == "jsonl" }
    }
    /// #30 §5: the UTC start of the OLDEST raw day file on disk — where a lifetime figure must start
    /// reading raw rows (`HistoryStore.lifetimeRows`). nil when there is no raw day file (or the
    /// directory cannot be listed, in which case no raw day can be read either).
    func oldestRawDayStart() -> Int? {
        (rawDayFiles() ?? []).compactMap { dayKey(fromCharge: $0.lastPathComponent) }
            .map { epoch(ofDay: $0) }
            .filter { $0 != 0 }                         // `epoch(ofDay:)` is 0 for a malformed name
            .map { HistoryFormat.utcDayStart($0) }.min()
    }
    /// #30 §5: every aggregate hour on disk, merged (the "all aggregates" windows: limit-hold hours,
    /// weekly medians). Callers stitch the raw days on top via `HistoryMetrics.stitched`.
    func allAggregates() -> [String: HourlyAggregate] {
        var out: [String: HourlyAggregate] = [:]
        // Display: an unlistable folder shows no aggregates; the Health note names the folder.
        for url in aggFiles() ?? [] {
            if let m = monthKey(fromAgg: url.lastPathComponent) { out.merge(readAggregate(m)) { a, _ in a } }
        }
        return out
    }

    /// The month aggregate files, or nil when the folder cannot be listed (unknown — never "none").
    private func aggFiles() -> [URL]? {
        (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("agg-") && $0.pathExtension == "json" }
    }
    private func dayKey(fromCharge name: String) -> String? {
        name.hasPrefix("charge-") ? String(name.dropFirst(7).dropLast(6)) : nil   // charge-…  .jsonl
    }
    private func monthKey(fromAgg name: String) -> String? {
        name.hasPrefix("agg-") ? String(name.dropFirst(4).dropLast(5)) : nil      // agg-…  .json
    }

    // MARK: - B9 memo helpers

    /// One `stat`. `FileManager.attributesOfItem` is used rather than `URL.resourceValues` on purpose:
    /// `NSURL` CACHES resource values on the URL instance, and a cached size would defeat the whole
    /// point of a freshness key.
    private func stamp(of url: URL) -> FileStamp? {
        guard let a = try? fm.attributesOfItem(atPath: url.path),
              let size = a[.size] as? Int,
              let m = a[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, mtime: m.timeIntervalSinceReferenceDate)
    }

    /// The rows of one raw day file to DISPLAY (`series`). An unreadable day shows as no rows; anything
    /// that folds or prunes must use `readRawDay` and act on the state.
    private func chargeRows(day: String) -> [ChargePoint] {
        if case .decoded(let rows, _) = readRawDay(day) { return rows }
        return []
    }

    /// The three-state raw read, decoded at most once per version of the file (B9). Decoding is per
    /// LINE from the bytes — not via `String(contentsOf:)`, which refuses a whole file over one invalid
    /// UTF-8 sequence — so a bad line costs that line, and is COUNTED rather than silently dropped.
    /// Access failures (no stat, no read) are not memoised, for the same reason as the month read.
    private func readRawDay(_ day: String) -> RawDayRead {
        let url = chargeURL(day)
        guard let s = stamp(of: url) else {
            chargeMemo[day] = nil
            if !fm.fileExists(atPath: url.path) { return .missing }
            logUnreadableOnce(url, "cannot be stat'ed")
            return .unreadable
        }
        if let hit = chargeMemo[day], hit.stamp == s { return hit.value }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            logUnreadableOnce(url, "cannot be read (\(error))")
            return .unreadable
        }
        fileDecodes += 1
        let (rows, bad) = decodeLines(data, as: ChargePoint.self)
        let read = RawDayRead.decoded(rows: rows, undecodableLines: bad)
        if chargeMemo.count >= Self.memoCap { chargeMemo.removeAll() }
        chargeMemo[day] = Memo(stamp: s, value: read)
        return read
    }

    private func logUnreadableOnce(_ url: URL, _ why: String) {
        guard unreadableFilesLogged.insert(url.lastPathComponent).inserted else { return }
        NSLog("battery_app: history file %@ %@ — treated as UNREADABLE (not as empty): left on disk "
              + "as-is, shown as no data, never folded into or overwritten.", url.path, why)
    }

    /// Drop any memo covering `url`. Called BEFORE every write this store makes, so a memo can never
    /// outlive the bytes it decoded even in the (vanishing) case of two writes sharing both a byte
    /// count and a modification timestamp. Health rows are not memoised, so `health.jsonl` matches
    /// neither key form and correctly falls through.
    private func invalidateMemo(for url: URL) {
        let name = url.lastPathComponent
        if let day = dayKey(fromCharge: name) { chargeMemo[day] = nil }
        else if let mk = monthKey(fromAgg: name) { aggMemo[mk] = nil }
    }

    // MARK: - codec + io

    /// B5: nil when the value cannot be represented — it used to fall back to a literal `"{}"`, which
    /// the caller wrote and counted as a landed row (the reader then dropped it as junk: a silent gap).
    private func encode<T: Encodable>(_ v: T) -> String? {
        (try? HistoryFormat.encoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) }
    }
    /// B5: pair each row with its encoded line, dropping — and COUNTING — every row the encoder rejects,
    /// so the writers can persist the good rows, retry only what is retryable, and never fake a row.
    private func encodable<T: Encodable>(_ rows: [T]) -> [(row: T, line: String)] {
        let pairs = rows.compactMap { r in encode(r).map { (row: r, line: $0) } }
        let dropped = rows.count - pairs.count
        if dropped > 0 {
            unencodableRowsDropped += dropped
            // Once per BATCH, not per row — and it should never fire at all. Same idiom as the other
            // "a silent fallback just happened" notices in the app (MenuBarBatteryIcon:454).
            NSLog("battery_app: history dropped %d unencodable %@ row(s) — JSONEncoder rejected them "
                  + "(non-finite value?). They are NOT in the file; total this session: %d.",
                  dropped, String(describing: T.self), unencodableRowsDropped)
        }
        return pairs
    }
    /// Decode newline-separated JSON from raw bytes, one line at a time. Empty lines are not lines;
    /// every other line either decodes or is COUNTED in `undecodable` — never just dropped.
    private func decodeLines<T: Decodable>(_ data: Data, as: T.Type) -> (rows: [T], undecodable: Int) {
        let dec = JSONDecoder()
        var rows: [T] = []
        var bad = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let r = try? dec.decode(T.self, from: Data(line)) { rows.append(r) } else { bad += 1 }
        }
        return (rows, bad)
    }
    /// Append lines via FileHandle (NOT atomic — a crash loses ≤1 partial-tail row, tolerated). Returns
    /// whether the write LANDED — S2: the caller (flush / recordHealth) acts on failure instead of
    /// swallowing it. Empty input is a no-op success.
    @discardableResult
    private func append(_ lines: [String], to url: URL) -> Bool {
        guard !lines.isEmpty else { return true }
        invalidateMemo(for: url)          // B9: about to change the bytes — drop the decode of the old ones
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if !fm.fileExists(atPath: url.path) {
            do { try data.write(to: url); return true } catch { return false }
        }
        guard let h = try? FileHandle(forUpdating: url) else { return false }
        defer { try? h.close() }
        // S2: seekToEnd is a HARD fail — never write at a stale/unknown offset (that corrupts earlier rows).
        guard let end = try? h.seekToEnd() else { return false }
        // Final review F8: a crash mid-append leaves a torn last line with no newline. Writing straight
        // after it glued the first good row onto the torn bytes, making it undecodable too — one crash
        // cost two rows. Start on a fresh line when the file does not end in one; the torn bytes stay,
        // on their own line, where the raw-day reader counts them (and keeps the file — c0fdb62).
        var payload = data
        if end > 0 {
            guard (try? h.seek(toOffset: end - 1)) != nil, let last = try? h.read(upToCount: 1) else { return false }
            if last.first != 0x0A { payload = Data([0x0A]) + data }
            guard (try? h.seekToEnd()) == end else { return false }   // back at the end, exactly
        }
        do { try h.write(contentsOf: payload); return true } catch { return false }
    }
    /// B9: memoised on the same key as the raw days. This one is read repeatedly WITHIN a single call
    /// as well as across calls — `series()` consults it once per raw-less day (a 12-month range asks the
    /// same month file ~30 times), and `runMaintenance` reads it in `aggregate` and again in
    /// `dayIsAggregated` for every day it prunes.
    ///
    /// The hours for DISPLAY (`series`, `allAggregates`, `dayIsAggregated`): an unreadable month shows as
    /// no hours. Anything that WRITES a month must use `readAggregateMonth` and refuse `.unreadable`.
    func readAggregate(_ month: String) -> [String: HourlyAggregate] {   // #30 §5/§14-D3: internal so HistoryMetrics can stitch it
        readAggregateMonth(month).hoursForDisplay
    }

    /// Redman "data loss": the three-state read. `.missing` only when there is no file at all; a file
    /// that is there but cannot be read OR decoded is `.unreadable`, never `[:]`. Memoised per file
    /// version like the decoded case, so an unreadable file is decoded — and logged — once per version
    /// of its bytes, not once per SwiftUI body evaluation.
    func readAggregateMonth(_ month: String) -> AggregateMonthRead {
        let url = aggURL(month)
        guard let s = stamp(of: url) else {
            aggMemo[month] = nil
            // No stat: usually "no file" — but a file whose attributes cannot be read is not absent.
            if !fm.fileExists(atPath: url.path) { return .missing }
            logUnreadableOnce(url, "cannot be stat'ed")
            return .unreadable
        }
        if let hit = aggMemo[month], hit.stamp == s { return hit.value }
        let d: Data
        do { d = try Data(contentsOf: url) } catch {
            // NOT memoised: a read failure is about the file's ACCESS, not its bytes, and repairing
            // access (a chmod) changes neither size nor mtime — a memo would hide the repair all session.
            // Logged once per file per session instead, since this path runs inside SwiftUI bodies.
            logUnreadableOnce(url, "cannot be read (\(error))")
            return .unreadable
        }
        fileDecodes += 1
        let read: AggregateMonthRead
        do {
            read = .decoded(try JSONDecoder().decode([String: HourlyAggregate].self, from: d))
        } catch {
            // Memoised (below): the same bytes always fail the same way, so this logs once per version.
            NSLog("battery_app: history month file %@ will not decode (%@) — it will not be shown, folded "
                  + "into or overwritten.", url.path, String(describing: error))
            read = .unreadable
        }
        if aggMemo.count >= Self.memoCap { aggMemo.removeAll() }
        aggMemo[month] = Memo(stamp: s, value: read)
        return read
    }
    /// Atomic write (temp + rename) — the aggregate file is never partial (the kill-test guard). Returns
    /// whether it LANDED (S3: a failed aggregate must not let the raw be pruned, and raises the stall signal).
    @discardableResult
    private func writeAggregate(_ agg: [String: HourlyAggregate], monthKey: String) -> Bool {
        guard let d = try? HistoryFormat.encoder().encode(agg) else { return false }
        invalidateMemo(for: aggURL(monthKey))   // B9: same rule as `append` — invalidate, then write
        do { try d.write(to: aggURL(monthKey), options: .atomic); return true } catch { return false }
    }

    // epoch helpers for a day/month key
    private func epoch(ofDay day: String) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, let d = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2])) else { return 0 }
        return Int(d.timeIntervalSince1970)
    }
    private func epoch(ofMonthEnd month: String) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let p = month.split(separator: "-").compactMap { Int($0) }
        guard p.count == 2,
              let start = cal.date(from: DateComponents(year: p[0], month: p[1], day: 1)),
              let next = cal.date(byAdding: .month, value: 1, to: start) else { return 0 }
        return Int(next.timeIntervalSince1970) - 1
    }
}
