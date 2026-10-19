import XCTest
import AppKit
@testable import Battery

/// Owner ruling 2026-09-09 evening: a helper process shows its PARENT app (Docker for the VM service,
/// Brave Browser for a renderer), a true daemon shows a category symbol + a human name, and every
/// symbol the table can return must exist on this OS (the DeviceIconTests discipline).
final class ProcessIdentityTests: XCTestCase {

    struct FakePaths: ProcessPathProviding {
        var paths: [Int: String]
        var responsible: [Int: Int] = [:]
        func executablePath(forPID pid: Int) -> String? { paths[pid] }
        func responsiblePID(forPID pid: Int) -> Int? { responsible[pid] }
    }

    /// Where the VM service REALLY lives on this Mac (probed 2026-09-09): the system framework, ppid
    /// launchd — only the responsible pid links it to Docker.
    static let systemVM = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    static let dockerVM = "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    static let braveHelper = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1.2/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"

    // MARK: parent app walk

    func testDockerVMServiceResolvesToDockerWithVMSubtitle() {
        let r = ProcessIdentity.resolve(pid: 10, name: "com.apple.Virtualization.VirtualMachine",
                                        paths: FakePaths(paths: [10: Self.dockerVM]))
        XCTAssertEqual(r.displayName, "Docker")
        XCTAssertEqual(r.subtitle, "VM service")
        XCTAssertEqual(r.icon, .appBundle(path: "/Applications/Docker.app"))
    }

    func testSystemFrameworkVMServiceResolvesThroughTheResponsiblePid() {
        let paths = FakePaths(paths: [10: Self.systemVM, 1777: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"],
                              responsible: [10: 1777])
        let r = ProcessIdentity.resolve(pid: 10, name: "com.apple.Virtualization.VirtualMachine", paths: paths)
        XCTAssertEqual(r.displayName, "Docker")
        XCTAssertEqual(r.subtitle, "VM service")
        XCTAssertEqual(r.icon, .appBundle(path: "/Applications/Docker.app"))
    }

    func testABareCLIKeepsItsOwnNameEvenWhenATerminalAppIsResponsible() {
        // `claude` under Ghostty: the OS holds Ghostty responsible, but the row must say "claude".
        let paths = FakePaths(paths: [20: "/Users/t/.local/share/claude/versions/2.1.265", 1452: "/Applications/Ghostty.app/Contents/MacOS/ghostty"],
                              responsible: [20: 1452])
        let r = ProcessIdentity.resolve(pid: 20, name: "claude", paths: paths)
        XCTAssertEqual(r.displayName, "claude")
        XCTAssertEqual(r.icon, .symbol("gearshape"))
        XCTAssertFalse(ProcessIdentity.isServiceLike(path: "/usr/bin/python3", name: "python3"))
        XCTAssertTrue(ProcessIdentity.isServiceLike(path: nil, name: "com.apple.WebKit.GPU"))
        XCTAssertTrue(ProcessIdentity.isServiceLike(path: "/x/Foo.xpc/Contents/MacOS/Foo", name: "Foo"))
    }

    func testBraveHelperResolvesToTheOutermostApp() {
        let r = ProcessIdentity.resolve(pid: 11, name: "Brave Browser Helper (Renderer)",
                                        paths: FakePaths(paths: [11: Self.braveHelper]))
        XCTAssertEqual(r.displayName, "Brave Browser")
        XCTAssertEqual(r.subtitle, "Renderer")
        XCTAssertEqual(r.icon, .appBundle(path: "/Applications/Brave Browser.app"), "outermost .app, not the nested Helper.app")
    }

    func testTheAppItselfHasNoSubtitle() {
        let r = ProcessIdentity.resolve(pid: 12, name: "Docker",
                                        paths: FakePaths(paths: [12: "/Applications/Docker.app/Contents/MacOS/Docker"]))
        XCTAssertEqual(r.displayName, "Docker")
        XCTAssertNil(r.subtitle)
    }

    func testHelperDescriptorsAreShortAndNoiseFree() {
        XCTAssertEqual(ProcessIdentity.helperDescriptor(processName: "Google Chrome Helper", appName: "Google Chrome"), "Helper")
        XCTAssertEqual(ProcessIdentity.helperDescriptor(processName: "Google Chrome Helper (GPU)", appName: "Google Chrome"), "GPU")
        XCTAssertEqual(ProcessIdentity.helperDescriptor(processName: "com.apple.WebKit.GPU.xpc", appName: "Safari"), "GPU")
        XCTAssertNil(ProcessIdentity.helperDescriptor(processName: "safari", appName: "Safari"))
        let long = ProcessIdentity.helperDescriptor(processName: "Xcode SomeVeryLongHelperNameHere", appName: "Xcode")!
        XCTAssertLessThanOrEqual(long.count, ProcessIdentity.subtitleMaxLength)
    }

    func testOutermostBundleWalk() {
        XCTAssertEqual(ProcessIdentity.outermostAppBundle(in: Self.braveHelper), "/Applications/Brave Browser.app")
        XCTAssertNil(ProcessIdentity.outermostAppBundle(in: "/usr/bin/python3"))
        XCTAssertNil(ProcessIdentity.outermostAppBundle(in: "/System/Library/Frameworks/.app/x"), "a bare '.app' component is not a bundle")
    }

    // MARK: daemon table

    func testBarePython3IsATerminalProcessWithItsNameKept() {
        let r = ProcessIdentity.resolve(pid: 13, name: "python3", paths: FakePaths(paths: [13: "/usr/bin/python3"]))
        XCTAssertEqual(r.displayName, "python3")
        XCTAssertNil(r.subtitle)
        XCTAssertEqual(r.icon, .symbol("terminal"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "python3.12").symbol, "terminal")
        for name in ["uv", "node", "ruby", "swift", "java"] {
            XCTAssertEqual(ProcessIdentity.daemon(named: name), ProcessIdentity.DaemonEntry(symbol: "terminal", name: name))
        }
    }

    func testKernelTaskIsTheCPUSymbolNamedKernel() {
        let r = ProcessIdentity.resolve(pid: 0, name: "kernel_task", paths: FakePaths(paths: [:]))
        XCTAssertEqual(r.displayName, "Kernel")
        XCTAssertEqual(r.icon, .symbol("cpu"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "kernel_coalition"), ProcessIdentity.DaemonEntry(symbol: "cpu", name: "Kernel"))
    }

    func testNamedDaemons() {
        XCTAssertEqual(ProcessIdentity.daemon(named: "WindowServer"), .init(symbol: "display", name: "Window Server"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "coreaudiod"), .init(symbol: "waveform", name: "Core Audio"))
        for m in ["mds", "mds_stores", "mdworker"] {
            XCTAssertEqual(ProcessIdentity.daemon(named: m), .init(symbol: "magnifyingglass", name: "Spotlight"))
        }
        XCTAssertEqual(ProcessIdentity.daemon(named: "bluetoothd"), .init(symbol: "wave.3.right", name: "Bluetooth"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "launchd"), .init(symbol: "gearshape", name: "launchd"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "com.apple.foo.xpc"), .init(symbol: "gearshape", name: "com.apple.foo.xpc"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "SomethingAgent"), .init(symbol: "gearshape", name: "SomethingAgent"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "Whatever"), .init(symbol: "gearshape", name: "Whatever"))
        XCTAssertEqual(ProcessIdentity.daemon(named: "/usr/libexec/coreaudiod").name, "Core Audio", "a path is matched on its last component")
    }

    // MARK: every symbol renders on this OS

    func testEveryDaemonSymbolRenders() {
        var seen = Set<String>()
        for name in ["kernel_task", "WindowServer", "coreaudiod", "mds", "bluetoothd", "python3", "launchd"] {
            let sym = ProcessIdentity.daemon(named: name).symbol
            XCTAssertNotNil(NSImage(systemSymbolName: sym, accessibilityDescription: nil), "\(name) → \(sym) missing on this OS")
            seen.insert(sym)
        }
        for sym in ProcessIdentity.daemonSymbols {
            XCTAssertNotNil(NSImage(systemSymbolName: sym, accessibilityDescription: nil), "\(sym) missing on this OS")
        }
        XCTAssertEqual(seen, Set(ProcessIdentity.daemonSymbols), "samples must cover every symbol the table can return")
        XCTAssertNotNil(NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil), "the icon-less bundle fallback")
    }
}
