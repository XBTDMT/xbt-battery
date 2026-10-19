import SwiftUI

/// Feature #13 Settings UI — mirrors NotificationSettingsView. The model owns the store; @Published
/// mirrors write through to the store, republish, AND invoke an injected `onChange` for an immediate
/// live glyph refresh (BatteryApp rerenders from its cached snapshot — no relaunch). App-only; NOT in
/// the test target (the store + the pure decision layer it drives are tested host-app-free).
@MainActor
final class GlyphSettingsModel: ObservableObject {

    private let store: GlyphPreferencesStore
    private let onChange: () -> Void

    @Published var displayMode: GlyphDisplayMode
    @Published var style: GlyphStyle

    init(store: GlyphPreferencesStore, onChange: @escaping () -> Void = {}) {
        self.store = store
        self.onChange = onChange
        self.displayMode = store.displayMode
        self.style = store.style
    }

    func setDisplayMode(_ mode: GlyphDisplayMode) {
        store.displayMode = mode
        displayMode = mode
        onChange()
    }

    func setStyle(_ newStyle: GlyphStyle) {
        store.style = newStyle
        style = newStyle
        onChange()
    }
}

struct GlyphSettingsView: View {

    @ObservedObject var model: GlyphSettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Show", selection: Binding(
                    get: { model.displayMode },
                    set: { model.setDisplayMode($0) })) {
                    Text("Icon and percentage").tag(GlyphDisplayMode.iconAndPercent)
                    Text("Icon only").tag(GlyphDisplayMode.iconOnly)
                    Text("Percentage only").tag(GlyphDisplayMode.percentOnly)
                }
                Picker("Style", selection: Binding(
                    get: { model.style },
                    set: { model.setStyle($0) })) {
                    Text("Native").tag(GlyphStyle.nativeContinuous)
                    Text("Apple SF Symbols").tag(GlyphStyle.sfSymbols)
                }
            } header: {
                Text("Menu bar icon")
            } footer: {
                if let note = GlyphDisplay.sfFidelityFooter(for: model.style) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
