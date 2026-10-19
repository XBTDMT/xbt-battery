import SwiftUI

/// #29 §4 `component.row` — a label:value row (label left, value right), min height 22 pt. The value
/// uses `type.rowValue` (monospaced digits) so live numbers don't jitter. Lives inside a `DSCard`.
struct DSRow<Value: View>: View {
    private let label: String
    private let value: Value

    init(_ label: String, @ViewBuilder value: () -> Value) {
        self.label = label
        self.value = value()
    }

    var body: some View {
        HStack(spacing: DSMetric.space2) {
            Text(label)
                .font(DSType.rowLabel)
                .foregroundStyle(DSColor.textSecondary)
            Spacer(minLength: DSMetric.space2)
            value
                .font(DSType.rowValue)
                .foregroundStyle(DSColor.textPrimary)
        }
        .frame(minHeight: DSMetric.rowMinHeight)
    }
}

extension DSRow where Value == Text {
    /// Convenience for a plain-text value.
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
    }
}
