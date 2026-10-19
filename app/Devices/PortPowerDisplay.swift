import Foundation

/// 31 §2.1 · "Powered by this Mac" as the Devices page prints it. PURE and host-app-free. Only derived,
/// rounded values live here (G-2): rows at 0.1 W, whole-watt contracts, a band SENTENCE, T/T′ as text, a
/// stale label — so a frame whose raw values moved but whose display did not compares equal and publishes
/// nothing.
struct PortPowerDisplay: Equatable, Sendable {
    enum Visibility: Equatable, Sendable {
        /// before the first read, never seen on this OS build, or nothing sourcing and nothing corroborated
        case hidden
        /// the latest read failed: "couldn't read ports", never stale rows (§3 rule 1)
        case unread
        case shown
    }

    enum RowState: Equatable, Sendable {
        /// element present and drawing (stage 3 hysteresis): tenths of a watt, tagged "exact" (T7)
        case drawing(tenthsW: Int)
        /// a corroborated device whose port does not draw — no power claim until U2/U4
        case notDrawing
        /// ≥ 2 ports source and the iPhone's port is not identified: listed once, without a watt figure
        case phonePortUnknown
    }

    struct Row: Equatable, Sendable, Identifiable {
        let id: String
        let symbol: String
        let name: String
        /// "· cable", or "· cable · 33% ⚡︎" for an iPhone with a sync reading
        let detail: String
        let state: RowState
        /// the negotiated PD contract in whole watts — hover / VoiceOver only ("up to 15 W"), never on the row
        let contractW: Int?
    }

    var visibility: Visibility = .hidden
    var rows: [Row] = []
    /// wired rows beyond `wiredRowCap` ("+N more")
    var overflow = 0
    /// the exact sum of every drawing port, in tenths of a watt; nil when nothing draws
    var totalTenthsW: Int? = nil
    /// true only when the same read's ExternalConnected says battery (unread → false: never yellow)
    var onBattery = false
    var costSentence: String? = nil
    var oneIsPhoneCaption = false
    var staleAsOf: String? = nil
    /// the iPhone is listed here, so the "Connected" card leaves it out (listed once, §1.3)
    var phoneInPowered = false

    static let hidden = PortPowerDisplay()
}

/// Everything `build` reads — the port source fills it from its own state (stage 3 + stage 4).
struct PortPowerDisplayInput {
    var everSeen: Bool
    var reading: PortPowerReading
    var drawing: Set<Int>
    var names: [Int: PortName]
    var phone: PhoneLink?
    /// from the same read's ExternalConnected: true = on battery, false = on power, nil = unread
    var onBattery: Bool?
    var band: OnPowerBand
    var cost: BatteryCostLine?
    var updateTime: Int?
    var now: Date
}

enum PortPowerDisplayModel {
    static let wiredRowCap = 3
    /// U2 + U4 (stage 0, spec §7.1): only once every load is proven to appear in PowerOutDetails does the
    /// header say "total".
    static let claimsTotal = false
    /// U2/U4: until a battery-less bus-powered device is proven to produce an element, a corroborated
    /// device on a quiet port reads "connected" (no power claim).
    static let notDrawingProven = false
    /// U3 (stage 0): false if the pack accumulators prove stale between %-steps — the on-power line then
    /// shows nothing and only the battery-cost line remains (§3 rule 4).
    static let onPowerLineEnabled = true
    static let staleAfter: TimeInterval = 120
    /// A non-breaking space after ">" so the sentence never ends a line on a lone ">".
    static let overTenHours = "> 10 h"
    static let bolt = "\u{26A1}\u{FE0E}"

    static var notDrawingWording: String { notDrawingProven ? "not drawing power" : "connected" }

    static func build(_ i: PortPowerDisplayInput) -> PortPowerDisplay {
        guard i.everSeen else { return .hidden }
        // The reading is decided BEFORE anything the source keeps across an unread (externalConnected,
        // updateTime, drawing, names): on `.unread` those hold their last good values and must never become rows.
        let ports: [PortPower]
        switch i.reading {
        case .notYetRead: return .hidden
        case .unread: return PortPowerDisplay(visibility: .unread)
        case .read(let read): ports = read
        }
        var byIndex: [Int: PortPower] = [:]
        for p in ports where byIndex[p.portIndex] == nil { byIndex[p.portIndex] = p }
        let names = i.names.filter { byIndex[$0.key] != nil }
        let drawing = byIndex.values.filter { i.drawing.contains($0.portIndex) }.sorted {
            // ordered on the ROUNDED figure: raw jitter inside a tenth must not reorder rows (G-2)
            tenths($0.filteredPower_mW) == tenths($1.filteredPower_mW)
                ? $0.portIndex < $1.portIndex : tenths($0.filteredPower_mW) > tenths($1.filteredPower_mW)
        }
        let phoneNamed = names.values.contains { $0.kind == .iphone }
        let phoneUnknown = i.phone?.usbPowered == true && !phoneNamed && drawing.count >= 2

        var rows: [PortPowerDisplay.Row] = []
        if phoneUnknown, let phone = i.phone {
            rows.append(.init(id: "phone", symbol: DeviceNaming.symbol(for: .iphone), name: "iPhone",
                              detail: phoneDetail(phone), state: .phonePortUnknown, contractW: nil))
        }
        for p in drawing {
            let n = names[p.portIndex]
            rows.append(.init(id: "port\(p.portIndex)", symbol: DeviceNaming.symbol(for: n?.kind),
                              name: n?.name ?? DeviceNaming.unnamedLabel, detail: detail(for: n, phone: i.phone),
                              state: .drawing(tenthsW: tenths(p.filteredPower_mW)), contractW: wholeWatts(p.contract_mW)))
        }
        for (index, n) in names.sorted(by: { $0.key < $1.key }) where !i.drawing.contains(index) {
            rows.append(.init(id: "port\(index)", symbol: DeviceNaming.symbol(for: n.kind), name: n.name,
                              detail: detail(for: n, phone: i.phone), state: .notDrawing,
                              contractW: wholeWatts(byIndex[index]?.contract_mW)))
        }
        guard !rows.isEmpty else { return .hidden }

        var d = PortPowerDisplay(visibility: .shown)
        d.rows = Array(rows.prefix(wiredRowCap))
        d.overflow = rows.count - d.rows.count
        d.totalTenthsW = drawing.isEmpty ? nil : drawing.reduce(0) { $0 + tenths($1.filteredPower_mW) }
        d.onBattery = i.onBattery == true
        if !drawing.isEmpty {
            switch i.onBattery {
            case true?: d.costSentence = i.cost.map { batteryCostSentence($0) }
            case false?: d.costSentence = onPowerLineEnabled ? bandSentence(i.band) : nil
            case nil: d.costSentence = nil
            }
        }
        d.oneIsPhoneCaption = phoneUnknown && drawing.contains { names[$0.portIndex] == nil }
        d.staleAsOf = staleStamp(updateTime: i.updateTime, now: i.now)
        d.phoneInPowered = phoneNamed || phoneUnknown
        return d
    }

    // MARK: - figures and sentences

    static func tenths(_ mW: Int) -> Int { Int((Double(mW) / 100).rounded()) }

    /// "9.2 W" — 0.1 W, the rows' and the HUD's precision.
    static func watts(tenths: Int) -> String { String(format: "%.1f W", Double(tenths) / 10) }

    /// "14.7 W"; on battery "14.7 W from battery"; "14.7 W total" only once U2 + U4 are proven.
    static func headerFigure(totalTenths: Int, onBattery: Bool) -> String {
        let w = watts(tenths: totalTenths)
        if onBattery { return "\(w) from battery" }
        return claimsTotal ? "\(w) total" : w
    }

    /// The one faint line under the card: the "one of these is the iPhone" caption and the "as of HH:mm" stamp share
    /// it ("one of these is the iPhone · as of 13:16", owner ruling Q3 B 2026-09-29); either alone shows alone.
    static func noteLine(oneIsPhoneCaption: Bool, staleAsOf: String?) -> String? {
        let parts = [oneIsPhoneCaption ? "one of these is the iPhone" : nil, staleAsOf].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "≈ 23% of your battery per hour — 43 min left with them, ≈ 1 h 32 m without"; T′ only when stage 3's
    /// guard produced it.
    static func batteryCostSentence(_ c: BatteryCostLine) -> String {
        // A port held on at 0.30–0.49 W rounds to 0 %/h; the line then says "< 1%", never "0%".
        let lead = c.percentPerHour < 1 ? formatPercent(c.percentPerHour) : "≈ " + formatPercent(c.percentPerHour)
        var s = "\(lead) of your battery per hour — \(formatDuration(c.timeLeft)) left with them"
        if let without = c.timeLeftWithout {
            let text = formatDuration(without)
            s += text == overTenHours ? ", \(text) without them" : ", ≈ \(text) without"
        }
        return s
    }

    /// "23%"; below one whole percent "< 1%" — never "0%" (S3.3 review: a 0.30–0.49 W port rounds to 0).
    static func formatPercent(_ p: Int) -> String { p < 1 ? "< 1%" : "\(p)%" }

    /// "38 min", "1 h 15 m", "2 h"; above 10 h "> 10 h" (§2.1).
    static func formatDuration(_ t: TimeInterval) -> String {
        // non-finite is "beyond the cap", never a trap in Int(NaN)
        if !t.isFinite || t > 10 * 3_600 { return overTenHours }
        let minutes = Int((t / 60).rounded())
        let (h, m) = (minutes / 60, minutes % 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    /// The on-power line (T8, G-6). `.none` — the dead band, a limit hold, anything unread — is no line.
    static func bandSentence(_ band: OnPowerBand) -> String? {
        switch band {
        case .headroom: return "Doesn't slow your Mac's charging"
        case .slower(let w): return "Your Mac charges ≈ \(w) W slower"
        case .fromBattery(let w): return "≈ \(w) W is coming from your battery"
        case .none: return nil
        }
    }

    /// "as of 12:55" when the newest frame is older than 120 s (§3 rule 6); nil otherwise or unread.
    /// A nil or FUTURE `updateTime` means "freshness unknown" → no label (the source reads every ~60 s).
    static func staleStamp(updateTime: Int?, now: Date, calendar: Calendar = .current) -> String? {
        guard let updateTime else { return nil }
        let frame = Date(timeIntervalSince1970: TimeInterval(updateTime))
        guard now.timeIntervalSince(frame) > staleAfter else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return "as of \(f.string(from: frame))"
    }

    /// X = port W ÷ pack Wh × 100 (§2.1), computed by `BatteryCost` so it is bit-for-bit the cost line's X.
    /// nil when the pack Wh is unread — the notice then shows watts only.
    /// A small port can round to 0: callers print it with `formatPercent`, which reads "< 1%", never "0%".
    static func percentPerHour(portWatts: Double, fullCharge_mAh: Int?, bankCount: Int?) -> Int? {
        guard portWatts > 0, let packWh = BatteryCost.packWh(fullCharge_mAh: fullCharge_mAh, bankCount: bankCount) else { return nil }
        return BatteryCost.percentPerHour(portWatts: portWatts, packWh: packWh)
    }

    /// The row's VoiceOver value: "9.2 watts, exact, up to 15 watts" ("exact" is the T7 tag the row figure carries).
    static func spokenValue(_ row: PortPowerDisplay.Row) -> String {
        switch row.state {
        case .drawing(let t):
            return String(format: "%.1f watts, exact", Double(t) / 10) + (row.contractW.map { ", up to \($0) watts" } ?? "")
        case .notDrawing:
            return notDrawingWording
        case .phonePortUnknown:
            // the row shows no watts, and that phone may be full and drawing ~0: claim only that it is connected
            return "connected, port not identified"
        }
    }

    /// The negotiated contract in whole watts. A contract of 0 (the parser allows it) or under 0.5 W is not a
    /// contract that was read: nil, so no "up to" clause is shown or spoken.
    private static func wholeWatts(_ mW: Int?) -> Int? {
        guard let mW, mW >= 500 else { return nil }
        return Int((Double(mW) / 1_000).rounded())
    }

    private static func phoneDetail(_ phone: PhoneLink) -> String {
        "· cable · \(phone.percent)%" + (phone.charging ? " \(bolt)" : "")
    }

    private static func detail(for name: PortName?, phone: PhoneLink?) -> String {
        guard name?.kind == .iphone, let phone else { return "· cable" }
        return phoneDetail(phone)
    }
}
