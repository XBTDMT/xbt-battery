import Foundation

/// Seam over the IOKit power-source reads so the model is testable with a mock. (SPEC WI-1.2; R-06.)
protocol PowerSourceReading: AnyObject {
    /// Raw IOPS description for the INTERNAL battery (nil if unavailable).
    func readLiveDescription() -> [String: Any]?
    /// Raw `AppleSmartBattery` property dict (nil if unavailable).
    func readDiagnosticsProperties() -> [String: Any]?
    /// Register the IOPS run-loop source on the MAIN run loop; `onChange` fires on the main thread.
    func startLiveUpdates(onChange: @escaping () -> Void)
    /// Remove + release the source (idempotent).
    func stopLiveUpdates()
}
