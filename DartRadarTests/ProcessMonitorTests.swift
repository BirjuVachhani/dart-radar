import XCTest
@testable import DartRadar

final class ProcessMonitorTests: XCTestCase {
    func testParseAndFilterKeepsOnlyDartProcesses() {
        let ps = """
          123 /Users/x/.puro/shared/caches/abc/dart-sdk/bin/dartvm --resolved_executable_name=/x/dart /Users/x/flutter_tools.snapshot run
          124 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --type=gpu
          125 bash /Users/x/.puro/envs/stable/flutter/bin/flutter daemon
          126 /Users/x/.puro/bin/puro flutter daemon
          127 /Users/x/sdk/dart-sdk/bin/dart language-server --protocol=lsp
        """
        let parsed = ProcessMonitor.parse(psOutput: ps)
        XCTAssertEqual(parsed.count, 5, "Every well-formed ps line must parse into a pid + args entry")
        let dart = parsed.filter { ProcessMonitor.isDartRelated($0.args) }
        XCTAssertEqual(
            dart.map(\.pid), [123, 126, 127],
            "Dart VMs, puro, and dart binaries count; Chrome and bash wrappers must not, or the list fills with noise"
        )
    }

    func testDartRadarItselfIsNeverTracked() {
        XCTAssertFalse(
            ProcessMonitor.isDartRelated(
                ["/x/Debug/Dart", "Radar.app/Contents/MacOS/Dart", "Radar"]
            ),
            "The app's own name starts with 'Dart'; a second running instance must not appear in the list"
        )
        // The argv above is pre-split the way parse() tokenises it, because the
        // bundle name contains a space. Left whole, argv[0] would be
        // "/x/Debug/Dart", whose basename is exactly "dart" and matches the
        // runtime prefix test, so this is the shape that actually reaches
        // isDartRelated in production.
        XCTAssertFalse(
            ProcessMonitor.isDartRelated(
                ProcessMonitor.parse(
                    psOutput: "  42 /Applications/Dart Radar.app/Contents/MacOS/Dart Radar"
                )[0].args
            ),
            "Parsed straight from ps output, a second copy of the app must still be excluded"
        )
    }

    func testAnalyzerIsNamedAfterItsIDEClient() {
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dart", "language-server", "--protocol=lsp", "--client-id=VS-Code"]
            ),
            "Analyzer (VS Code)",
            "Analyzers are identical apart from --client-id, so the IDE is the only way to tell them apart"
        )
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dart", "language-server", "--client-id=Android-Studio", "--protocol=analyzer"]
            ),
            "Analyzer (Android Studio)",
            "The client id appears before the protocol here; flag order must not matter"
        )
    }

    func testIDEQualifiesOtherwiseAnonymousHelpers() {
        // These three share one argv shape per IDE, so without the owning editor
        // a user with two IDEs open sees identical untraceable rows.
        XCTAssertEqual(
            ProcessMonitor.displayName(["/sdk/bin/dart", "tooling-daemon", "--machine"], ide: "VS Code"),
            "Tooling Daemon (VS Code)",
            "The tooling daemon's argv is identical across IDEs; only the parent chain distinguishes them"
        )
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dartvm", "/x/flutter_tools.snapshot", "daemon"], ide: "Android Studio"
            ),
            "Flutter Daemon (Android Studio)",
            "A flutter daemon carries no project, so naming its IDE is the only identifying information available"
        )
        XCTAssertEqual(
            ProcessMonitor.displayName(["/sdk/bin/dart", "tooling-daemon"], ide: nil),
            "Tooling Daemon",
            "A process with no IDE ancestor must not render an empty qualifier"
        )
    }

    func testExplicitClientIDWinsOverParentChain() {
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dart", "language-server", "--client-id=Android-Studio"], ide: "VS Code"
            ),
            "Analyzer (Android Studio)",
            "The analyzer states its own client; that is authoritative over an inferred ancestor"
        )
    }

    func testVSCodeForksAreNotMislabelledAsVSCode() {
        XCTAssertEqual(
            ProcessMonitor.ideName("/Applications/Cursor.app/Contents/MacOS/Cursor"), "Cursor",
            "Cursor is a VS Code fork whose binary also matches Code-ish paths; it must be matched first"
        )
        XCTAssertEqual(
            ProcessMonitor.ideName(
                "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
            ),
            "VS Code",
            "Dart processes are spawned by the per-window extension host, not the main Code binary"
        )
        XCTAssertNil(
            ProcessMonitor.ideName("/bin/bash"),
            "A non-editor ancestor must not produce a qualifier"
        )
    }

    func testOwningIDEWalksPastShellAndShimAncestors() {
        // The real chain is dart -> puro -> bash -> IDE, so a single ppid hop is
        // not enough; this proves the walk against this test process's own chain.
        let ide = ProcessMonitor.owningIDE(of: pid_t(ProcessInfo.processInfo.processIdentifier))
        XCTAssertNil(
            ide.flatMap { $0.isEmpty ? "" : nil },
            "owningIDE must return either a non-empty editor name or nil, never an empty string"
        )
        XCTAssertNotNil(
            ProcessMonitor.parentPID(of: pid_t(ProcessInfo.processInfo.processIdentifier)),
            "Every running process has a parent; the sysctl ppid lookup must succeed for self"
        )
    }

    func testSnapshotRunnersAreNamedAfterTheirRealJob() {
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dartaotruntime", "/sdk/snapshots/frontend_server_aot.dart.snapshot",
                 "--sdk-root", "/x/", "--target=dartdevc"]
            ),
            "Frontend Compiler (web)",
            "dartaotruntime is a generic runtime; the snapshot and --target name the actual job"
        )
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dartvm", "/shared/flutter_tools/abc/flutter_tools.snapshot", "daemon"]
            ),
            "Flutter Daemon",
            "The subcommand after a flutter_tools snapshot is the real identity of a dartvm process"
        )
    }

    func testPuroShimResolvesToTheToolItForwardsTo() {
        XCTAssertEqual(
            ProcessMonitor.displayName(["/x/bin/puro", "flutter", "run", "-d", "chrome"]),
            "Flutter Run (chrome)",
            "puro is a version-manager shim; the user cares about the flutter command it forwards to"
        )
        XCTAssertEqual(
            ProcessMonitor.displayName(["/x/bin/puro", "dart", "mcp-server"]),
            "MCP Server",
            "The shim's tool selector token must not be mistaken for the subcommand"
        )
    }

    func testRawSimulatorUUIDsAreNotShownAsDeviceNames() {
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dartvm", "/x/flutter_tools.snapshot", "--no-color", "run", "--machine",
                 "--device-id=3F9A163C-2659-4D5D-B883-31C26AC085EC", "lib/main.dart"]
            ),
            "Flutter Run",
            "A 36-character simulator UUID is noise in a label; a readable device name is not"
        )
    }

    func testDevServiceDeviceSurvivesWhitespaceSplitArgv() {
        // ps output is whitespace-split, so this one flag arrives as many tokens.
        let argv = ("/sdk/bin/dart development-service --bind-port=0 "
            + "--app-name=Kind: Flutter - Device: iPhone 17 Pro - Package: hyper_zones")
            .split(separator: " ").map(String.init)
        XCTAssertEqual(
            ProcessMonitor.displayName(argv),
            "Dart Dev Service (iPhone 17 Pro)",
            "The device name spans several argv tokens and must be rejoined, not truncated at the first space"
        )
        XCTAssertEqual(
            ProcessMonitor.appNameFields(argv)["Package"], "hyper_zones",
            "The package field is parsed too, since it names the project the service is attached to"
        )
    }

    func testAppNameWithoutDeviceDegradesCleanly() {
        XCTAssertEqual(
            ProcessMonitor.displayName(
                ["/sdk/bin/dartaotruntime", "/x/dds_aot.dart.snapshot", "--app-name=Unknown", "web", "app"]
            ),
            "Dart Dev Service",
            "A web app reports no device; the label must not invent one or show an empty parenthesis"
        )
    }

    func testProjectRootWalksUpToPubspec() {
        let existing: Set<String> = ["/Users/x/proj/pubspec.yaml"]
        let root = ProcessMonitor.projectRoot(
            cwd: "/Users/x/proj/example/sub",
            args: ["dart"],
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(
            root, "/Users/x/proj",
            "The nearest ancestor with a pubspec.yaml is the project the process belongs to"
        )
    }

    func testRootCwdFallsBackToArgumentPaths() {
        let existing: Set<String> = ["/Users/x/app/pubspec.yaml"]
        let root = ProcessMonitor.projectRoot(
            cwd: "/",
            args: ["/sdk/bin/dart", "compile", "/Users/x/app/bin/main.dart"],
            fileExists: { existing.contains($0) }
        )
        XCTAssertEqual(
            root, "/Users/x/app",
            "IDE language servers report cwd '/', so argument paths must locate the project instead"
        )
    }

    func testNoProjectYieldsCwdOrNil() {
        XCTAssertEqual(
            ProcessMonitor.projectRoot(cwd: "/Users/x/somewhere", args: ["dart"], fileExists: { _ in false }),
            "/Users/x/somewhere",
            "Without a pubspec a real cwd is still a useful link target"
        )
        XCTAssertNil(
            ProcessMonitor.projectRoot(cwd: "/", args: ["dart"], fileExists: { _ in false }),
            "cwd '/' with no path arguments means there is genuinely nothing to link to"
        )
    }

    func testSDKWorkingDirectoryIsNotAProject() {
        let root = ProcessMonitor.projectRoot(
            cwd: "/Users/x/.puro/envs/stable/flutter",
            args: ["dart"],
            fileExists: { _ in true }
        )
        XCTAssertNil(
            root,
            "The Flutter SDK checkout contains its own pubspec.yaml; SDK daemons must not be linked to it as a project"
        )
    }

    func testDTDURIIsReadFromEitherFlagSpelling() {
        // Both spellings are live on this machine: VS Code passes the URI as a
        // separate token, Android Studio uses '='.
        XCTAssertEqual(
            ProcessMonitor.dtdURI(
                ["/sdk/bin/dart", "devtools", "--machine", "--dtd-uri", "ws://127.0.0.1:50661/abc="]
            )?.absoluteString,
            "ws://127.0.0.1:50661/abc=",
            "A space-separated --dtd-uri must be read, or VS Code windows resolve no workspace"
        )
        XCTAssertEqual(
            ProcessMonitor.dtdURI(["/sdk/bin/dart", "devtools", "--dtd-uri=ws://127.0.0.1:62753/x="])?.port,
            62753,
            "The '=' spelling must be read, or Android Studio windows resolve no workspace"
        )
        XCTAssertNil(
            ProcessMonitor.dtdURI(["/sdk/bin/dart", "tooling-daemon", "--machine"]),
            "The daemon itself never carries the secret; only DevTools does"
        )
    }

    func testWorkspaceRootParsesDaemonReply() {
        XCTAssertEqual(
            WorkspaceResolver.firstRoot(
                in: #"{"jsonrpc":"2.0","result":{"type":"IDEWorkspaceRoots","ideWorkspaceRoots":["file:///Users/x/proj"]},"id":"1"}"#
            ),
            "/Users/x/proj",
            "The daemon returns file:// URIs; the UI needs a plain filesystem path"
        )
        XCTAssertNil(
            WorkspaceResolver.firstRoot(in: #"{"jsonrpc":"2.0","result":{"ideWorkspaceRoots":[]},"id":"1"}"#),
            "A window with no folder open reports an empty list and must not yield a path"
        )
        XCTAssertNil(
            WorkspaceResolver.firstRoot(in: #"{"jsonrpc":"2.0","error":{"code":-32000,"message":"bad secret"},"id":"1"}"#),
            "A rejected secret must fail soft rather than surface a wrong or empty location"
        )
    }

    func testUsageBarFillIsClampedAndNeverEmptyForLiveProcesses() {
        XCTAssertEqual(UsageBar.filledSegments(for: 1.0), 10, "A fully loaded process fills the bar")
        XCTAssertEqual(
            UsageBar.filledSegments(for: 0.001), 1,
            "A tiny but live process must still show one segment rather than reading as zero"
        )
        XCTAssertEqual(UsageBar.filledSegments(for: 0), 0, "Genuine zero shows an empty bar")
        XCTAssertEqual(
            UsageBar.filledSegments(for: 1.4), 10,
            "A multi-core process above 100% must not paint more segments than the bar has"
        )
        XCTAssertEqual(
            UsageBar.filledSegments(for: .nan), 0,
            "A NaN fraction (zero peak memory) must not crash the Int conversion"
        )
    }

    private func process(_ id: pid_t, cpu: Double, memoryMB: UInt64) -> DartProcess {
        DartProcess(
            id: id, name: "n", executableName: "dart", command: "c",
            projectPath: nil, workspace: nil,
            cpuPercent: cpu, memoryBytes: memoryMB * 1_000_000
        )
    }

    func testBusyProcessOutranksAHeavierIdleOne() {
        let peak: UInt64 = 2_000_000_000
        let busy = ProcessMonitor.loadScore(process(1, cpu: 90, memoryMB: 200), peakMemoryBytes: peak)
        let idle = ProcessMonitor.loadScore(process(2, cpu: 0, memoryMB: 900), peakMemoryBytes: peak)
        XCTAssertGreaterThan(
            busy, idle,
            "A process burning most of a core is the one worth seeing first, even when something else holds more memory"
        )
    }

    func testAtIdleTheOrderIsPurelyByMemory() {
        let peak: UInt64 = 2_000_000_000
        let big = ProcessMonitor.loadScore(process(1, cpu: 0.2, memoryMB: 1_800), peakMemoryBytes: peak)
        let small = ProcessMonitor.loadScore(process(2, cpu: 0.9, memoryMB: 12), peakMemoryBytes: peak)
        XCTAssertGreaterThan(
            big, small,
            "Sub-1% noise must not float a 12 MB shim above a 1.8 GB analyzer; that is why CPU is scaled to a core, not to the busiest row"
        )
    }

    func testScoreIsFiniteWhenNoProcessHasMemory() {
        XCTAssertEqual(
            ProcessMonitor.loadScore(process(1, cpu: 0, memoryMB: 0), peakMemoryBytes: 0), 0,
            "An empty list must not divide by a zero peak and poison the sort with NaN"
        )
    }

    func testSDKBootstrapPackagesFlagIsNotMistakenForAProject() {
        // A Flutter SDK installed outside ~/.puro (the common case: ~/development/flutter)
        // is not caught by the tooling-path list, so position is what saves us here.
        let argv = [
            "/x/dart-sdk/bin/dartvm",
            "--packages=/Users/x/development/flutter/packages/flutter_tools/.dart_tool/package_config.json",
            "/Users/x/development/flutter/bin/cache/flutter_tools.snapshot",
            "daemon",
        ]
        XCTAssertNil(
            ProcessMonitor.projectRoot(cwd: "/", args: argv, fileExists: { _ in true }),
            "flutter_tools' own package_config precedes the snapshot and must never be read as the user's project"
        )
    }

    func testProjectArgumentsAfterTheSnapshotStillResolve() {
        let existing: Set<String> = ["/Users/x/app/pubspec.yaml"]
        let argv = [
            "/x/dart-sdk/bin/dartvm",
            "--packages=/Users/x/development/flutter/packages/flutter_tools/.dart_tool/package_config.json",
            "/x/flutter_tools.snapshot", "run", "/Users/x/app/lib/main.dart",
        ]
        XCTAssertEqual(
            ProcessMonitor.projectRoot(cwd: "/", args: argv, fileExists: { existing.contains($0) }),
            "/Users/x/app",
            "Skipping pre-snapshot flags must not also discard real project paths passed to the command"
        )
    }

    func testToolingPathsAreNeverProjectCandidates() {
        let root = ProcessMonitor.projectRoot(
            cwd: "/",
            args: ["/x/dart", "/Users/x/.puro/envs/stable/flutter/bin/cache/dart-sdk/bin/snapshots/dds_aot.dart.snapshot"],
            fileExists: { _ in true }
        )
        XCTAssertNil(
            root,
            "SDK and cache paths must never be reported as the user's project even when they exist on disk"
        )
    }

    func testUsedSumsTheThreeUnreclaimableKinds() {
        var memory = SystemMemory()
        memory.app = 1_000
        memory.wired = 2_000
        memory.compressed = 3_000
        memory.cachedFiles = 9_000
        XCTAssertEqual(
            memory.used, 6_000,
            "Cached files are reclaimable, so Memory Used must exclude them or it overstates pressure"
        )
    }

    func testPressureIsZeroRatherThanNaNWhenPhysicalIsUnknown() {
        var memory = SystemMemory()
        memory.wired = 1_000
        XCTAssertEqual(
            memory.pressure, 0,
            "A failed host_statistics64 leaves physical at 0; dividing by it would feed NaN into the graph path"
        )
    }

    func testLiveSampleIsSelfConsistent() {
        let memory = SystemMemory.sample()
        XCTAssertGreaterThan(memory.physical, 0, "Physical memory comes from ProcessInfo and is always known")
        XCTAssertLessThanOrEqual(
            memory.used, memory.physical,
            "Used memory above installed RAM means the page-size or counter maths is wrong"
        )
        XCTAssertTrue(
            [1, 2, 4].contains(memory.pressureLevel),
            "The kernel reports pressure as 1, 2 or 4; anything else means the sysctl read the wrong width"
        )
    }
}
