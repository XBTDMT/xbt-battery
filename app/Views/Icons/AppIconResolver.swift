import AppKit

/// #30 R11 / §4.2: the app-icon rule. A ranked "who spent it" row shows the REAL icon of the running
/// process, and `gearshape` for daemons / non-GUI processes. The AppKit fetch sits behind this seam so
/// the choice policy (`AppIconPolicy`) is pure and tested with a dictionary-backed provider.
protocol AppIconProviding {
    /// The running process's icon, or nil when the pid is not a GUI app (see §14-B12 rule) / gone.
    func icon(forPID pid: Int) -> NSImage?
    /// The icon of the installed app with this bundle identifier, or nil when none is installed.
    func icon(forBundleID bundleID: String) -> NSImage?
}

/// Production provider. §14-B12 rule: `NSRunningApplication(processIdentifier:)` resolves for ANY pid
/// (daemons included) and hands back a generic icon for bundle-less processes — so the icon is
/// returned ONLY when `bundleURL != nil && activationPolicy != .prohibited`; everything else is nil and
/// falls to the policy's symbol. Sustained rows carry no pid (§14-B12), so they resolve by bundle id via
/// `NSWorkspace`. App-side AppKit only — never the helper.
final class RunningAppIconProvider: AppIconProviding {
    init() {}

    func icon(forPID pid: Int) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)),
              let url = app.bundleURL, app.activationPolicy != .prohibited,
              Self.bundleDeclaresIcon(url) else { return nil }
        return app.icon
    }

    /// Stage-3 finding on device: dozens of accessory agents and .xpc services (WebKit GPU, the Docker VM
    /// service, WidgetRenderer…) have a bundle URL and a non-prohibited policy but no icon file, so
    /// `app.icon` hands back the blank generic-document image. An icon is only "real" when the bundle's
    /// Info.plist declares one (CFBundleIconFile / CFBundleIconName / CFBundleIcons); otherwise the row
    /// falls to the gearshape symbol like any daemon.
    static func bundleDeclaresIcon(_ url: URL) -> Bool {
        guard let info = Bundle(url: url)?.infoDictionary else { return false }
        return info["CFBundleIconFile"] != nil || info["CFBundleIconName"] != nil || info["CFBundleIcons"] != nil
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// What a row draws: the process's real icon, or an SF Symbol name.
enum AppIconChoice {
    case image(NSImage)
    case symbol(String)

    var symbolName: String? { if case .symbol(let s) = self { return s } else { return nil } }
    var isImage: Bool { if case .image = self { return true } else { return false } }
}

/// The pure choice policy.
enum AppIconPolicy {
    /// R11: `gearshape` for daemons / non-GUI processes; `app.dashed` for an app we could not identify
    /// at all (no pid to ask about and no installed bundle) — a placeholder that reads as "an app",
    /// not as "a system service".
    static func fallbackSymbol(isDaemon: Bool) -> String {
        isDaemon ? "gearshape" : "app.dashed"
    }

    /// pid first (the live process — §4.2), then the bundle id (§14-B12: Sustained rows have no pid),
    /// then a symbol. A pid that resolved to no GUI icon is a non-GUI process → daemon fallback; a row
    /// with NO pid whose bundle is not installed is an unidentified app → `app.dashed`.
    static func choose(pid: Int?, bundleID: String?, provider: AppIconProviding) -> AppIconChoice {
        if let pid, let image = provider.icon(forPID: pid) { return .image(image) }
        if let bundleID, !bundleID.isEmpty, let image = provider.icon(forBundleID: bundleID) { return .image(image) }
        return .symbol(fallbackSymbol(isDaemon: pid != nil))
    }
}

// MARK: - process identity (owner ruling 2026-09-09 evening: one ranking, real names, no gearshape wall)

/// Seam over `proc_pidpath` so the parent-app walk is unit-tested with fake paths. App-side and
/// unprivileged: same-uid processes resolve, other uids return nil (never an error, never the helper).
protocol ProcessPathProviding {
    func executablePath(forPID pid: Int) -> String?
    /// The pid the OS holds RESPONSIBLE for this one (what Activity Monitor groups under) — the link
    /// from a system-framework XPC service (Docker's VM lives in Virtualization.framework, ppid launchd)
    /// back to the app that spawned it. nil when unknown or when the process is its own responsible.
    func responsiblePID(forPID pid: Int) -> Int?
}

/// Production provider: libproc's `proc_pidpath` (public API, no entitlement). nil on EPERM / gone.
/// The responsible-pid lookup is `responsibility_get_pid_responsible_for_pid` from libsystem — not in a
/// public header, so it is reached by `dlsym` and degrades to nil when absent (personal-use app,
/// decision #4; app-side only, never the helper).
struct LibprocProcessPathProvider: ProcessPathProviding {
    init() {}
    func executablePath(forPID pid: Int) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))   // PROC_PIDPATHINFO_MAXSIZE
        let n = proc_pidpath(pid_t(pid), &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    func responsiblePID(forPID pid: Int) -> Int? {
        guard let fn = Self.responsibleFn else { return nil }
        let r = fn(pid_t(pid))
        return (r > 0 && Int(r) != pid) ? Int(r) : nil
    }
}

/// The PURE identity policy: a sampled process name (+ its executable path via the seam) → the name a
/// row shows, an optional helper descriptor, and where its icon comes from. AppKit never enters here;
/// `LiveDrawerIdentityResolver` turns `.appBundle` into an `NSImage` and `.symbol` into an SF Symbol.
enum ProcessIdentity {

    enum IconSource: Equatable {
        /// An enclosing `.app` bundle (the OUTERMOST one on the path — Brave Browser.app, not the
        /// Brave Browser Helper.app nested inside its Frameworks).
        case appBundle(path: String)
        /// A category SF Symbol from the daemon table.
        case symbol(String)
    }

    struct Resolved: Equatable {
        let displayName: String
        /// "VM service" / "Helper" / "Renderer" — set only when the process is not the app itself.
        let subtitle: String?
        let icon: IconSource
    }

    /// Longest helper descriptor a row shows (mock: the faint subtitle must not push the bar).
    static let subtitleMaxLength = 14

    // MARK: parent app

    /// The OUTERMOST `…/Name.app` prefix of `path`, or nil when no component ends in ".app".
    static func outermostAppBundle(in path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return parts[...index].joined(separator: "/")
    }

    /// "Docker" for "/Applications/Docker.app" — the bundle's file name minus the extension. The live
    /// resolver upgrades this to the bundle's localized name when it declares one.
    static func appName(forBundlePath path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }

    /// A short descriptor for a helper process: the process name with the app's name (and the noise
    /// words "Helper", parentheses, dots) stripped, e.g. "Brave Browser Helper (Renderer)" → "Renderer";
    /// "com.apple.Virtualization.VirtualMachine" → "VM service"; "Google Chrome Helper" → "Helper".
    /// nil when the process IS the app (same name) or nothing meaningful is left.
    static func helperDescriptor(processName: String, appName: String) -> String? {
        let name = processName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.caseInsensitiveCompare(appName) != .orderedSame else { return nil }
        let lower = name.lowercased()
        if lower.contains("virtualization") || lower.contains("virtualmachine") || lower.hasSuffix(".vm") {
            return "VM service"
        }
        if lower.hasSuffix(".xpc") || lower.contains("xpc") {
            return descriptorFromXPC(name) ?? "Service"
        }
        var rest = name
        if let range = rest.range(of: appName, options: .caseInsensitive) { rest.removeSubrange(range) }
        rest = rest.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        let words = rest.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).map(String.init)
        let kept = words.filter { $0.caseInsensitiveCompare("Helper") != .orderedSame }
        let descriptor = kept.isEmpty ? (words.isEmpty ? "" : "Helper") : kept.joined(separator: " ")
        return clamp(descriptor)
    }

    /// "com.apple.WebKit.GPU" → "GPU"; "com.apple.Virtualization.VirtualMachine" is caught earlier.
    private static func descriptorFromXPC(_ name: String) -> String? {
        var trimmed = name
        if trimmed.hasSuffix(".xpc") { trimmed = String(trimmed.dropLast(4)) }
        guard let last = trimmed.split(separator: ".").last.map(String.init), !last.isEmpty,
              last.caseInsensitiveCompare("xpc") != .orderedSame else { return nil }
        return clamp(last)
    }

    private static func clamp(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return t.count <= subtitleMaxLength ? t : String(t.prefix(subtitleMaxLength - 1)) + "…"
    }

    // MARK: daemon table

    struct DaemonEntry: Equatable {
        let symbol: String
        let name: String
    }

    /// Every symbol the table can return (the render test walks this list, like `DeviceIcon.allSymbols`).
    static let daemonSymbols: [String] = ["cpu", "display", "waveform", "magnifyingglass", "wave.3.right", "terminal", "gearshape"]

    /// Category symbol + human name for a process with no enclosing `.app`. Matched on the executable
    /// name (the last path component of the sampled name), case-insensitively.
    static func daemon(named rawName: String) -> DaemonEntry {
        let raw = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = raw.split(separator: "/").last.map(String.init) ?? raw
        let name = base.isEmpty ? raw : base
        let lower = name.lowercased()
        switch lower {
        case "kernel_task", "kernel_coalition":            return DaemonEntry(symbol: "cpu", name: "Kernel")
        case "windowserver":                                return DaemonEntry(symbol: "display", name: "Window Server")
        case "coreaudiod":                                  return DaemonEntry(symbol: "waveform", name: "Core Audio")
        case "mds", "mds_stores", "mdworker", "mdworker_shared", "mdsync", "mdbulkimport":
            return DaemonEntry(symbol: "magnifyingglass", name: "Spotlight")
        case "bluetoothd":                                  return DaemonEntry(symbol: "wave.3.right", name: "Bluetooth")
        default: break
        }
        if lower.hasPrefix("python") || ["uv", "node", "ruby", "swift", "java", "perl", "bun", "deno"].contains(lower) {
            return DaemonEntry(symbol: "terminal", name: name)
        }
        return DaemonEntry(symbol: "gearshape", name: name)   // "…d", agents, xpc services, everything else
    }

    // MARK: resolve

    /// A process that cannot stand on its own in a ranking — an XPC service or a bundle-id-named
    /// executable — so its RESPONSIBLE app is the honest row. A bare CLI (`claude`, `python3`) is NOT one:
    /// it keeps its own name even though the OS holds the terminal app responsible for it.
    static func isServiceLike(path: String?, name: String) -> Bool {
        if let path, path.contains(".xpc/") || path.contains("/XPCServices/") { return true }
        let n = name.lowercased()
        return n.hasSuffix(".xpc") || (n.hasPrefix("com.") && n.contains("."))
    }

    /// The bundle for a pid: its own path's outermost `.app`, else — for a service-like process — the
    /// outermost `.app` of the pid the OS holds responsible for it.
    static func parentBundle(pid: Int, name: String, paths: ProcessPathProviding) -> String? {
        let own = paths.executablePath(forPID: pid)
        if let own, let bundle = outermostAppBundle(in: own) { return bundle }
        guard isServiceLike(path: own, name: name), let responsible = paths.responsiblePID(forPID: pid),
              let path = paths.executablePath(forPID: responsible) else { return nil }
        return outermostAppBundle(in: path)
    }

    /// The pure resolution: path (or the responsible app's path) → outermost app (name + helper
    /// subtitle + bundle icon), else the daemon table. `name` is the sampled process name.
    static func resolve(pid: Int?, name: String, paths: ProcessPathProviding) -> Resolved {
        if let pid, let bundle = parentBundle(pid: pid, name: name, paths: paths) {
            let app = appName(forBundlePath: bundle)
            return Resolved(displayName: app, subtitle: helperDescriptor(processName: name, appName: app),
                            icon: .appBundle(path: bundle))
        }
        let entry = daemon(named: name)
        return Resolved(displayName: entry.name, subtitle: nil, icon: .symbol(entry.symbol))
    }
}

/// What a ranked row shows once identity is settled: name · faint subtitle · icon.
struct DrawerIdentity {
    let displayName: String
    let subtitle: String?
    let icon: AppIconChoice
}

/// Seam over the whole identity lookup so the harness and the pure drawers model never touch AppKit.
protocol DrawerIdentityResolving {
    func identity(pid: Int?, bundleID: String?, name: String) -> DrawerIdentity
}

/// Production resolver. Order: (1) a real running GUI app by pid keeps its own icon + name; (2) the
/// executable path's outermost `.app` (Docker for its VM service, Brave Browser for its renderers) with
/// the bundle's icon when it declares one; (3) a Sustained coalition's installed bundle by id; (4) the
/// daemon table. A row never falls to a bare gearshape when its parent app is knowable.
final class LiveDrawerIdentityResolver: DrawerIdentityResolving {
    private let icons: any AppIconProviding
    private let paths: any ProcessPathProviding
    init(icons: any AppIconProviding = RunningAppIconProvider(), paths: any ProcessPathProviding = LibprocProcessPathProvider()) {
        self.icons = icons; self.paths = paths
    }

    func identity(pid: Int?, bundleID: String?, name: String) -> DrawerIdentity {
        if let pid, let image = icons.icon(forPID: pid) {
            return DrawerIdentity(displayName: name, subtitle: nil, icon: .image(image))
        }
        let resolved = ProcessIdentity.resolve(pid: pid, name: name, paths: paths)
        switch resolved.icon {
        case .appBundle(let path):
            let url = URL(fileURLWithPath: path)
            let localized = Self.localizedName(ofBundleAt: url) ?? resolved.displayName
            let subtitle = ProcessIdentity.helperDescriptor(processName: name, appName: localized) ?? resolved.subtitle
            if RunningAppIconProvider.bundleDeclaresIcon(url) {
                return DrawerIdentity(displayName: localized, subtitle: subtitle,
                                      icon: .image(NSWorkspace.shared.icon(forFile: path)))
            }
            return DrawerIdentity(displayName: localized, subtitle: subtitle, icon: .symbol("app.dashed"))
        case .symbol(let symbol):
            if let bundleID, !bundleID.isEmpty, bundleID.contains("."), let image = icons.icon(forBundleID: bundleID) {
                return DrawerIdentity(displayName: name, subtitle: nil, icon: .image(image))
            }
            return DrawerIdentity(displayName: resolved.displayName, subtitle: nil, icon: .symbol(symbol))
        }
    }

    private static func localizedName(ofBundleAt url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let s = bundle.localizedInfoDictionary?[key] as? String, !s.isEmpty { return s }
            if let s = bundle.infoDictionary?[key] as? String, !s.isEmpty { return s }
        }
        return nil
    }
}
