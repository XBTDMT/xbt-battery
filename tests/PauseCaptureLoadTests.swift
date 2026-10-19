import XCTest

/// SWEEP H2 (`knowledge/12-SWEEP-silent-absence.md`): a corrupt pause capture must not read as
/// "never paused".
///
/// RED-FIRST RECORD — every test below was written against the pre-fix file and could not COMPILE,
/// which is the strongest form the RED signal takes here: the old API had no vocabulary in which the
/// distinction could even be stated. `PauseCaptureStoring.load() -> PauseCapture?` returned the same
/// `nil` for "nothing stored" and "the stored bytes will not decode", so no assertion over the old
/// surface could have told them apart. The `.corrupt` case IS the fix; these tests are its proof.
///
/// The real `UserDefaultsPauseCaptureStore` is exercised over REAL bytes in a named suite, not a
/// stand-in — a fake store has no decode step and so could never have shown the `try?` was the defect.
final class PauseCaptureLoadTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: UserDefaultsPauseCaptureStore!

    override func setUp() {
        super.setUp()
        suiteName = "PauseCaptureLoadTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = UserDefaultsPauseCaptureStore(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil; store = nil; suiteName = nil
        super.tearDown()
    }

    private func writeGarbage() {
        // Bytes that are present but are not a `PauseCapture` — a schema change or a truncated write.
        defaults.set(Data("{\"pauseTarget\":".utf8), forKey: UserDefaultsPauseCaptureStore.key)
    }

    // MARK: - the distinction itself

    func testNothingStoredReadsAsTheLegitimateEmpty() {
        XCTAssertEqual(store.loadDetailed(), .none)
    }

    func testACorruptCaptureIsDistinguishableFromTheLegitimateEmpty() {
        writeGarbage()
        XCTAssertEqual(store.loadDetailed(), .corrupt)
        XCTAssertNotEqual(store.loadDetailed(), PauseCaptureLoad.none,
                          "the whole defect: an undecodable capture used to be indistinguishable from no capture")
    }

    func testADecodableCaptureRoundTrips() {
        let c = PauseCapture(pausedFromLimit: 85, pauseTarget: 80, capturedAt: Date(timeIntervalSince1970: 1_000))
        store.save(c)
        XCTAssertEqual(store.loadDetailed(), .capture(c))
        XCTAssertEqual(store.loadDetailed().capture, c)
    }

    func testClearReturnsTheStoreToTheLegitimateEmptyNotToCorrupt() {
        writeGarbage()
        XCTAssertEqual(store.loadDetailed(), .corrupt)
        store.clear()
        XCTAssertEqual(store.loadDetailed(), .none, "clear() must not leave a corrupt latch behind")
    }

    // MARK: - what the three states MEAN

    func testACorruptCaptureStillMeansChargingIsPaused() {
        // The defect, stated as behaviour: only `pause()` ever writes this key, so bytes under it are
        // evidence a pause happened. Reading them as "not paused" strands the machine at the pause
        // target with no pause shown and no Resume offered — a VANISHED latch (ISSUE-11's mirror).
        writeGarbage()
        XCTAssertTrue(store.loadDetailed().indicatesPaused)
    }

    func testTheLegitimateEmptyMeansNotPaused() {
        XCTAssertFalse(store.loadDetailed().indicatesPaused)
    }

    func testADecodableCaptureMeansPausedWithItsRestorePointIntact() {
        store.save(PauseCapture(pausedFromLimit: 90, pauseTarget: 85, capturedAt: Date()))
        XCTAssertTrue(store.loadDetailed().indicatesPaused)
        XCTAssertFalse(store.loadDetailed().restorePointLost)
    }

    func testOnlyACorruptCaptureReportsALostRestorePoint() {
        XCTAssertFalse(PauseCaptureLoad.none.restorePointLost,
                       "no pause means no restore point to lose — never warn about one")
        XCTAssertFalse(PauseCaptureLoad.capture(PauseCapture(pausedFromLimit: nil, pauseTarget: 80,
                                                             capturedAt: Date())).restorePointLost,
                       "a capture whose pausedFromLimit was UNKNOWN at pause time is a read that SUCCEEDED — "
                       + "it already resolves to 100 by documented design, and is not a lost restore point")
        XCTAssertTrue(PauseCaptureLoad.corrupt.restorePointLost)
    }

    // MARK: - the preserved call shape

    func testTheLegacyLoadShimIsBehaviourPreservingForCorrupt() {
        // Deliberate: `load()` still answers nil for `.corrupt`, so every existing caller is
        // byte-identical. The honest answer is available ONLY to a caller that asks for it — which is
        // why the ChargeLimitEngine wiring (init's `isPaused`, resume's disclosure) is the remaining
        // owed step, in a file this pass does not own.
        writeGarbage()
        XCTAssertNil(store.load())
        XCTAssertEqual(store.loadDetailed(), .corrupt)
    }

    /// A store that does NOT override `loadDetailed()` — the protocol-extension default, which has no
    /// decode step and therefore cannot reach `.corrupt`. (`MockPauseCaptureStore` now overrides it, so
    /// it is no longer the witness for this.)
    private final class DefaultingStore: PauseCaptureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var c: PauseCapture?
        func load() -> PauseCapture? { lock.lock(); defer { lock.unlock() }; return c }
        func save(_ x: PauseCapture) { lock.lock(); c = x; lock.unlock() }
        func clear() { lock.lock(); c = nil; lock.unlock() }
    }

    func testAStoreWithNoDecodeStepInheritsTheDefaultAndNeverReportsCorrupt() {
        let plain = DefaultingStore()
        XCTAssertEqual(plain.loadDetailed(), .none)
        let c = PauseCapture(pausedFromLimit: 80, pauseTarget: 80, capturedAt: Date())
        plain.save(c)
        XCTAssertEqual(plain.loadDetailed(), .capture(c))
    }

    func testTheTestDoubleCanStateAllThreeStates() {
        let mock = MockPauseCaptureStore()
        XCTAssertEqual(mock.loadDetailed(), .none)
        let c = PauseCapture(pausedFromLimit: 80, pauseTarget: 80, capturedAt: Date())
        mock.save(c)
        XCTAssertEqual(mock.loadDetailed(), .capture(c))
        XCTAssertEqual(MockPauseCaptureStore(corrupt: true).loadDetailed(), .corrupt)
    }

    // MARK: - SCHEMA TOLERANCE (the prerequisite: a version bump must not mass-produce `.corrupt`)
    //
    // `.corrupt ⇒ paused` is only safe if `.corrupt` stays RARE. `PauseCapture` carries no version
    // field, so the moment a later release adds a stored property, every blob written by the previous
    // release lacks that key — and under the SYNTHESIZED `Decodable` a missing key throws. Combined
    // with the new default that would mean: **every upgrade looks like a pause**, on every machine, at
    // once. These tests pin the decoder's tolerance so that cannot happen.

    /// The exact upgrade shape: bytes written before `invalidatedByExternalChange` existed. This is
    /// not hypothetical — it is what the v1 key holds on any machine that paused before that field
    /// was added.
    func testABlobMissingAFieldTheCurrentStructHasStillDecodes() {
        defaults.set(Data(#"{"pauseTarget":85,"capturedAt":1000,"pausedFromLimit":100}"#.utf8),
                     forKey: UserDefaultsPauseCaptureStore.key)
        XCTAssertEqual(store.loadDetailed(),
                       .capture(PauseCapture(pausedFromLimit: 100, pauseTarget: 85,
                                             capturedAt: Date(timeIntervalSinceReferenceDate: 1000),
                                             invalidatedByExternalChange: false)),
                       "a field added after the blob was written must fall back to its default, not throw")
    }

    /// The mirror: bytes from a LATER release, read by this one (a downgrade, or a synced prefs file).
    func testABlobCarryingAnUnknownFieldStillDecodes() {
        defaults.set(Data(#"{"pauseTarget":90,"capturedAt":1000,"pauseReason":"thermal","v":7}"#.utf8),
                     forKey: UserDefaultsPauseCaptureStore.key)
        XCTAssertEqual(store.loadDetailed().capture?.pauseTarget, 90,
                       "an unrecognised key is not a corrupt capture")
        XCTAssertFalse(store.loadDetailed().restorePointLost)
    }

    /// The minimum a blob must carry. Both keys have been written by every version that has ever
    /// existed, so no upgrade can lack them — they are what makes the record a capture at all.
    func testTheEssentialKeysAreTheOnlyOnesRequired() {
        defaults.set(Data(#"{"pauseTarget":80,"capturedAt":0}"#.utf8),
                     forKey: UserDefaultsPauseCaptureStore.key)
        XCTAssertEqual(store.loadDetailed().capture?.pausedFromLimit, nil)
        XCTAssertEqual(store.loadDetailed().capture?.pauseTarget, 80)
    }

    /// The boundary, stated so it is not mistaken for a bug: tolerance is for ADDITIVE change. Bytes
    /// with no pause target are not a lenient capture, they are unreadable — and `.corrupt` is the
    /// honest answer, which now means "paused, restore point lost".
    func testABlobMissingAnEssentialKeyIsStillCorrupt() {
        defaults.set(Data(#"{"capturedAt":0,"invalidatedByExternalChange":false}"#.utf8),
                     forKey: UserDefaultsPauseCaptureStore.key)
        XCTAssertEqual(store.loadDetailed(), .corrupt)
    }

    /// THE TRIPWIRE FOR THE NEXT AUTHOR. The tolerant decoder is hand-written, so a property added to
    /// the struct is encoded by the synthesized `encode(to:)` but silently ignored unless the author
    /// also adds a `decodeIfPresent` line. That failure is safe (a lost field, never a corrupt storm)
    /// but it is still a bug, and a full-fidelity round trip is what catches it.
    func testEveryEncodedFieldSurvivesARoundTrip() {
        let c = PauseCapture(pausedFromLimit: 95, pauseTarget: 90,
                             capturedAt: Date(timeIntervalSinceReferenceDate: 12_345),
                             invalidatedByExternalChange: true)
        store.save(c)
        XCTAssertEqual(store.loadDetailed(), .capture(c),
                       "a field the encoder writes but the hand-written decoder ignores fails here")
    }

    /// Truncation is still corrupt — the tolerance must not swallow the case the whole type exists for.
    func testTolerantDecodingDidNotSwallowRealCorruption() {
        writeGarbage()
        XCTAssertEqual(store.loadDetailed(), .corrupt)
        defaults.set(Data("not json at all".utf8), forKey: UserDefaultsPauseCaptureStore.key)
        XCTAssertEqual(store.loadDetailed(), .corrupt)
    }
}
