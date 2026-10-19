import SwiftUI

/// #29 §4 — the segmented control used by the Charge limit card (80 / 90 / 100) and elsewhere. A thin
/// token-styled wrapper over the native segmented picker so the design layer owns the styling seam.
struct DSSegmentedControl<T: Hashable>: View {
    struct Option: Identifiable {
        let value: T
        let label: String
        var id: T { value }
    }

    @Binding private var selection: T
    private let options: [Option]

    init(selection: Binding<T>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    /// Convenience: build options from (value, label) pairs.
    init(selection: Binding<T>, _ pairs: [(T, String)]) {
        self._selection = selection
        self.options = pairs.map { Option(value: $0.0, label: $0.1) }
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.label).tag(option.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }
}
