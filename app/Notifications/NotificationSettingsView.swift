import SwiftUI
import AppKit

/// Sprint 4.4 Settings UI (SPEC sec 1/2). Lives in the previously-empty `Settings { }` scene (the
/// architect ruling on the Settings-access STOP: filling a declared-but-empty scene is not touching
/// the frozen popover/menu). The master toggle requests authorization ONLY on enable; a denied state
/// is shown honestly with a deep link to System Settings → Notifications, never a nag.
///
/// App-only (SwiftUI + the live UN center), like `BatteryPopoverView`. The logic it drives — the
/// enable controller, the prefs store — is tested host-app-free.

private let notificationsSystemSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

/// View-model bridging the Settings UI to the pure store + the authorization seam. Owns the single
/// live `LiveNotificationCenter` instance, which it also vends as the coordinator's presenter so one
/// center both authorizes and posts.
@MainActor
final class NotificationSettingsModel: ObservableObject {

    let store: NotificationPreferencesStore
    private let center: any NotificationAuthorizing & NotificationPresenting
    private let enableController: NotificationEnableController

    @Published var masterEnabled: Bool
    @Published var lowBatteryThreshold: Int
    @Published var authState: NotificationAuthState = .notDetermined
    @Published private var enabledByType: [NotificationEventType: Bool]

    init(store: NotificationPreferencesStore = NotificationPreferencesStore(),
         center: (any NotificationAuthorizing & NotificationPresenting) = LiveNotificationCenter()) {
        self.store = store
        self.center = center
        self.enableController = NotificationEnableController(authorizer: center)
        self.masterEnabled = store.masterEnabled
        self.lowBatteryThreshold = store.lowBatteryThreshold
        self.enabledByType = Dictionary(uniqueKeysWithValues:
            NotificationEventType.allCases.map { ($0, store.isEnabled($0)) })
    }

    /// The coordinator posts through the SAME live center instance.
    var presenter: any NotificationPresenting { center }

    func isEnabled(_ type: NotificationEventType) -> Bool { enabledByType[type] ?? false }

    func setEnabled(_ on: Bool, for type: NotificationEventType) {
        store.setEnabled(on, for: type)
        enabledByType[type] = on
    }

    /// Write the low-battery threshold through to the store and republish (mirrors setEnabled/setMaster).
    func setLowBatteryThreshold(_ value: Int) {
        store.lowBatteryThreshold = value
        lowBatteryThreshold = value
    }

    /// Flipping the master toggle is the ONLY explicit act that may request authorization (SPEC sec 1).
    func setMaster(_ on: Bool) {
        store.masterEnabled = on
        masterEnabled = on
        if on {
            Task { authState = await enableController.userEnabledNotifications() }
        }
    }

    /// Refresh the honest auth state when Settings appears — never prompts.
    func refreshAuth() {
        Task { authState = await enableController.refreshStatus() }
    }
}

struct NotificationSettingsView: View {

    @ObservedObject var model: NotificationSettingsModel
    /// 31 §2.2 (T9, Q2): its own key, always visible, independent of the notifications master switch — the
    /// notice is an on-screen HUD, not a notification.
    @AppStorage(DeviceNoticeSetting.key) private var deviceNoticeOn = DeviceNoticeSetting.defaultOn

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: Binding(
                    get: { model.masterEnabled },
                    set: { model.setMaster($0) }))
                .toggleStyle(.switch)
            } footer: {
                if model.masterEnabled, model.authState == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications are turned off for Battery in System Settings, so nothing will be delivered.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Notification Settings…") {
                            NSWorkspace.shared.open(notificationsSystemSettingsURL)
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    Text("Battery stays silent by default. Turn this on to get a few useful, restrained alerts.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.masterEnabled {
                Section("Notify me about") {
                    eventToggle("Fully charged", .fullyCharged)
                    eventToggle("Charge limit reached", .limitReached)
                    eventToggle("Top Up complete", .topUpComplete)
                    eventToggle("Scheduled limit applied", .scheduledApplied)
                    eventToggle("Low battery", .lowBattery)
                    Picker("Warn at", selection: Binding(
                        get: { model.lowBatteryThreshold },
                        set: { model.setLowBatteryThreshold($0) })) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { pct in
                            Text("\(pct)%").tag(pct)
                        }
                    }
                    // #EI-4 / C4. Opt-in and OFF by default: the popover Temperature row is the
                    // always-available, non-interrupting surface, and this only fires on the rising
                    // edge of a genuine heat episode (42 °C, re-armed below 37 °C).
                    eventToggle("Battery running hot", .hotBattery)
                    eventToggle("Charge control problems", .setupProblem)
                }
                .disabled(model.authState == .denied)
            }

            Section {
                Toggle("Show a notice when a device starts drawing power from the Mac", isOn: $deviceNoticeOn)
                    .toggleStyle(.switch)
                    .help("On battery only, while you're using the Mac. It can take up to about 2 minutes after you plug a device in.")
            } footer: {
                Text("A brief on-screen notice, not a notification")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshAuth() }
    }

    @ViewBuilder
    private func eventToggle(_ title: String, _ type: NotificationEventType) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.isEnabled(type) },
            set: { model.setEnabled($0, for: type) }))
        .toggleStyle(.switch)
    }
}
