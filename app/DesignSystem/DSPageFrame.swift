import SwiftUI

/// Spec 31 §2.5 (G-3, T11) · the ONE page frame. Replaces the five hand-written page frames — Day (fixed,
/// centre), Energy and Health (fixed, top), Devices and Now (max-height, centre) — preserving each one
/// exactly (`.frame(...)` then `.clipped()`), and gives the clip gate its measurement channel. Automation is
/// not framed here: it is a ScrollView and reports through its own `ContentHeightKey`.
enum DSPageFrameMode {
    /// `.frame(height: DSMetric.pageHeight)` — the page is always exactly the frame.
    case fixed
    /// `.frame(maxHeight: DSMetric.pageHeight)` — the page may be shorter than the frame.
    case maxHeight
}

/// Which of the render harness's two passes is running.
enum PageMeasureChannel: Sendable {
    /// Pass 1: the page in its real frame; report the content height laid out INSIDE it.
    case inside
    /// Pass 2: the page at its `.fixedSize` natural height (text free to grow); report that.
    case natural
}

/// The render harness's end of the gate. nil in every normal launch, so production layout is the plain
/// frame with no probe attached.
struct PageMeasurementSink: Sendable {
    let channel: PageMeasureChannel
    /// Called on EVERY change of the measured height (not once in `onAppear`); the harness keeps the last
    /// value it sees after its settle. `scrollCue` is Automation's scroll flag + bottom-fade cue.
    let report: @MainActor @Sendable (_ height: CGFloat, _ scrollCue: Bool) -> Void
}

private struct PageMeasurementKey: EnvironmentKey {
    static let defaultValue: PageMeasurementSink? = nil
}

private struct FixtureNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// The clip gate's sink (render harness only).
    var pageMeasurement: PageMeasurementSink? {
        get { self[PageMeasurementKey.self] }
        set { self[PageMeasurementKey.self] = newValue }
    }

    /// Spec 31 §2.6 · the render harness's pinned "now". Pages read `fixtureNow ?? Date()`; nil in every
    /// normal launch.
    var fixtureNow: Date? {
        get { self[FixtureNowKey.self] }
        set { self[FixtureNowKey.self] = newValue }
    }
}

struct DSPageFrame: ViewModifier {
    let mode: DSPageFrameMode
    let alignment: Alignment
    @Environment(\.pageMeasurement) private var sink

    @ViewBuilder func body(content: Content) -> some View {
        if let sink, sink.channel == .natural {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(Self.probe(sink))
        } else if let sink {
            framed(content.background(Self.probe(sink)))
        } else {
            framed(content)
        }
    }

    @ViewBuilder private func framed<Page: View>(_ page: Page) -> some View {
        switch mode {
        case .fixed:     page.frame(height: DSMetric.pageHeight, alignment: alignment).clipped()
        case .maxHeight: page.frame(maxHeight: DSMetric.pageHeight, alignment: alignment).clipped()
        }
    }

    /// Measures the content (not the frame): in pass 1 a page whose content outgrows 470 reports > 470.
    @MainActor private static func probe(_ sink: PageMeasurementSink) -> some View {
        GeometryReader { g in
            Color.clear.onChange(of: g.size.height, initial: true) { _, height in
                sink.report(height, false)
            }
        }
    }
}

extension View {
    /// Spec 31 §2.5: the page frame + clip-gate channel. See `DSPageFrame`.
    func dsPageFrame(_ mode: DSPageFrameMode, alignment: Alignment) -> some View {
        modifier(DSPageFrame(mode: mode, alignment: alignment))
    }
}
