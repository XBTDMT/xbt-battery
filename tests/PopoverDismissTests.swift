import XCTest

/// #22 (SPEC sec 1): the install/remove PAIRING — the correctness core — under repeated
/// open/close cycles, every close path, and idempotency. The live NSEvent tap is seamed out.
@MainActor
final class PopoverDismissTests: XCTestCase {

    /// Mock monitor that records install/remove and tracks live state exactly like the real one
    /// (idempotent install = remove-then-install; never stacks).
    final class MockGlobalClickMonitor: GlobalClickMonitoring {
        private(set) var installs = 0
        private(set) var removes = 0
        private(set) var maxConcurrent = 0
        private var live = 0
        var onClick: (() -> Void)?
        var isInstalled: Bool { live > 0 }

        func install(onClick: @escaping () -> Void) {
            if live > 0 { remove() }            // idempotent: never stack
            self.onClick = onClick
            live += 1
            installs += 1
            maxConcurrent = max(maxConcurrent, live)
        }
        func remove() {
            if live > 0 { live -= 1; removes += 1 }
            onClick = nil
        }
        /// Simulate an outside click reaching the installed monitor.
        func fireOutsideClick() { onClick?() }
    }

    private func makeCoordinator() -> (PopoverDismissCoordinator, MockGlobalClickMonitor, () -> Int) {
        let monitor = MockGlobalClickMonitor()
        var closeCalls = 0
        let coord = PopoverDismissCoordinator(monitor: monitor, requestClose: { closeCalls += 1 })
        return (coord, monitor, { closeCalls })
    }

    func testSingleOpenCloseInstallsThenRemovesExactlyOnce() {
        let (coord, monitor, _) = makeCoordinator()
        coord.didShow()
        XCTAssertTrue(monitor.isInstalled)
        coord.didClose()
        XCTAssertFalse(monitor.isInstalled)
        XCTAssertEqual(monitor.installs, 1)
        XCTAssertEqual(monitor.removes, 1)
    }

    func testRepeatedCyclesNeverLeakOrStack() {
        let (coord, monitor, _) = makeCoordinator()
        for _ in 0..<25 {
            coord.didShow()
            coord.didClose()
        }
        XCTAssertEqual(monitor.installs, 25)
        XCTAssertEqual(monitor.removes, 25)
        XCTAssertFalse(monitor.isInstalled, "no monitor may survive a closed popover")
        XCTAssertEqual(monitor.maxConcurrent, 1, "never more than one live monitor (no stacking)")
    }

    func testOutsideClickPathRequestsCloseWhichRemovesMonitor() {
        let (coord, monitor, closeCalls) = makeCoordinator()
        coord.didShow()
        monitor.fireOutsideClick()             // outside click → requestClose
        XCTAssertEqual(closeCalls(), 1)
        // In the app, requestClose → performClose → popoverDidClose → didClose. Simulate that tail.
        coord.didClose()
        XCTAssertFalse(monitor.isInstalled)
        XCTAssertEqual(monitor.installs, monitor.removes)
    }

    func testResignActiveRequestsCloseAndTailRemovesMonitor() {
        let (coord, monitor, closeCalls) = makeCoordinator()
        coord.didShow()
        coord.resignActive()                   // cmd-tab → requestClose
        XCTAssertEqual(closeCalls(), 1)
        coord.didClose()                       // the close tail
        XCTAssertFalse(monitor.isInstalled)
    }

    func testStatusItemRetoggleClosePathRemovesMonitor() {
        // Second status-item click → performClose directly (no monitor involvement) → didClose.
        let (coord, monitor, closeCalls) = makeCoordinator()
        coord.didShow()
        coord.didClose()                       // togglePopover's performClose tail
        XCTAssertEqual(closeCalls(), 0, "the status-item path does not go through requestClose")
        XCTAssertFalse(monitor.isInstalled)
        XCTAssertEqual(monitor.installs, monitor.removes)
    }

    func testDoubleCloseIsIdempotent() {
        let (coord, monitor, _) = makeCoordinator()
        coord.didShow()
        coord.didClose()
        coord.didClose()                       // a stray second close must not go negative
        XCTAssertFalse(monitor.isInstalled)
        XCTAssertEqual(monitor.removes, 1, "idempotent: the tap is really removed once; the second close is a no-op")
    }

    func testInstallWhileAlreadyInstalledDoesNotStack() {
        // Defensive: a double didShow (e.g. duplicate notification) must not leave two taps.
        let (coord, monitor, _) = makeCoordinator()
        coord.didShow()
        coord.didShow()
        XCTAssertEqual(monitor.maxConcurrent, 1, "idempotent install removes the prior tap")
        coord.didClose()
        XCTAssertFalse(monitor.isInstalled)
    }
}
