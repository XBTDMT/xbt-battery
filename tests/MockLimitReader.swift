import Foundation

/// Scripted LimitReading for WI-N4/N5 tests. Supports PARKING a call on a continuation so the
/// race test can interleave a cancel between "verdict ready" and "read-back returns".
actor MockLimitReader: LimitReading {

    private var responses: [ChargeLimitValue]
    private(set) var calls = 0

    private var parkNextCall = false
    private var parked: CheckedContinuation<Void, Never>?
    private var parkObservers: [CheckedContinuation<Void, Never>] = []

    /// Responses are consumed in order; the LAST one repeats forever.
    init(_ responses: [ChargeLimitValue] = [.known(80)]) {
        precondition(!responses.isEmpty)
        self.responses = responses
    }

    func script(_ newResponses: [ChargeLimitValue]) {
        precondition(!newResponses.isEmpty)
        responses = newResponses
    }

    /// The NEXT readLimit() call parks until `release()`.
    func parkNext() { parkNextCall = true }

    /// Suspends the TEST until a reader call is actually parked (the race choreography point).
    func waitUntilParked() async {
        if parked != nil { return }
        await withCheckedContinuation { parkObservers.append($0) }
    }

    func release() {
        parked?.resume()
        parked = nil
    }

    func readLimit() async -> ChargeLimitValue {
        calls += 1
        if parkNextCall {
            parkNextCall = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                parked = c
                let observers = parkObservers
                parkObservers.removeAll()
                for o in observers { o.resume() }
            }
        }
        let value = responses.count > 1 ? responses.removeFirst() : responses[0]
        return value
    }
}
