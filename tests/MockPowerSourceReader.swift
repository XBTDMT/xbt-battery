import Foundation
// app/Monitoring sources are compiled into the BatteryTests target, so PowerSourceReading et al.
// are visible here without a host app.

/// Test double for `PowerSourceReading` — returns injected fixtures and can fire the change
/// callback on demand. Lives in `tests/` only (no app call site → not in the app target). (SPEC WI-1.2.)
final class MockPowerSourceReader: PowerSourceReading {
    var liveDescription: [String: Any]?
    var diagnosticsProperties: [String: Any]?
    private var onChange: (() -> Void)?

    init(live: [String: Any]? = nil, diagnostics: [String: Any]? = nil) {
        self.liveDescription = live
        self.diagnosticsProperties = diagnostics
    }

    func readLiveDescription() -> [String: Any]? { liveDescription }
    func readDiagnosticsProperties() -> [String: Any]? { diagnosticsProperties }
    func startLiveUpdates(onChange: @escaping () -> Void) { self.onChange = onChange }
    func stopLiveUpdates() { onChange = nil }

    /// Trigger the stored change callback (simulates a plug/unplug / %-change event).
    func fireChange() { onChange?() }
}
