import Darwin
import Foundation
import Observation

struct DartProcess: Identifiable, Equatable {
    let id: pid_t
    let name: String
    /// The executable as the OS knows it (dartvm, dartaotruntime, puro …),
    /// kept alongside `name` because the two are deliberately different.
    let executableName: String
    let command: String
    let projectPath: String?
    /// IDE workspace owning this process, for processes that have no project
    /// of their own. Ownership context, not a project link.
    let workspace: String?
    let cpuPercent: Double
    let memoryBytes: UInt64

    var projectName: String? { projectPath.map { ($0 as NSString).lastPathComponent } }

    /// Full project path with the home directory abbreviated to "~".
    var projectDisplayPath: String? {
        projectPath.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }
}

@MainActor @Observable
final class ProcessMonitor {
    private(set) var processes: [DartProcess] = []

    var totalMemoryBytes: UInt64 { processes.reduce(0) { $0 + $1.memoryBytes } }
    var totalCPUPercent: Double { processes.reduce(0) { $0 + $1.cpuPercent } }
    var totalMemoryText: String { Self.memoryText(totalMemoryBytes) }
    /// Heaviest process, used to normalise the per-row memory bars.
    var peakMemoryBytes: UInt64 { processes.map(\.memoryBytes).max() ?? 0 }

    private(set) var memory = SystemMemory()
    /// Rolling pressure samples for the header graph, newest last.
    private(set) var pressureHistory: [Double] = []
    /// 60 samples at the 2s tick, so the graph spans about two minutes.
    static let historyLength = 60

    private var previousCPUNanos: [pid_t: (nanos: UInt64, at: ContinuousClock.Instant)] = [:]
    // Neither a process's project nor its owning IDE changes while it lives,
    // so both are resolved once per pid rather than on every 2s tick.
    private var projectCache: [pid_t: String?] = [:]
    private var nameCache: [pid_t: String] = [:]
    // Keyed by IDE-window pid, so one DTD round trip serves every process that
    // window spawned. nil is cached too: a window whose daemon did not answer
    // is not retried for the lifetime of the app.
    // ponytail: one attempt per window; add a retry if daemons prove slow to start.
    private var workspaceByWindow: [pid_t: String?] = [:]
    private var resolvingWindows: Set<pid_t> = []

    init() {
        Task {
            while !Task.isCancelled {
                await sample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func sample() async {
        memory = SystemMemory.sample()
        pressureHistory.append(memory.pressure)
        if pressureHistory.count > Self.historyLength {
            pressureHistory.removeFirst(pressureHistory.count - Self.historyLength)
        }
        let output = await Task.detached(priority: .utility) { Self.listProcesses() }.value
        let now = ContinuousClock.now
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let parsed = Self.parse(psOutput: output)

        // One DTD per editor window. Scanned before filtering, since the
        // DevTools process carrying the secret is itself a Dart process.
        var dtdByWindow: [pid_t: URL] = [:]
        var ambiguousWindows: Set<pid_t> = []
        for (pid, args) in parsed {
            guard let uri = Self.dtdURI(args),
                  let window = Self.ideAncestor(of: pid)?.pid else { continue }
            if let existing = dtdByWindow[window], existing != uri {
                // Android Studio hosts every window in one process, so two
                // daemons can share an ancestor. Refuse rather than guess.
                ambiguousWindows.insert(window)
            }
            dtdByWindow[window] = uri
        }
        for window in ambiguousWindows { dtdByWindow.removeValue(forKey: window) }

        for (window, uri) in dtdByWindow
        where workspaceByWindow[window] == nil && !resolvingWindows.contains(window) {
            resolvingWindows.insert(window)
            Task { [weak self] in
                let root = await WorkspaceResolver.workspaceRoot(dtd: uri)
                await self?.storeWorkspace(root, for: window)
            }
        }

        var seen = Set<pid_t>()
        var next: [DartProcess] = []
        for (pid, args) in parsed where pid != ownPID && Self.isDartRelated(args) {
            // A pid that vanished between ps and here just gets skipped this tick.
            guard let usage = Self.usage(of: pid) else { continue }
            seen.insert(pid)

            var cpu = 0.0
            if let previous = previousCPUNanos[pid], usage.cpuNanos >= previous.nanos {
                let wall = previous.at.duration(to: now)
                let wallNanos = Double(wall.components.seconds) * 1e9
                    + Double(wall.components.attoseconds) * 1e-9
                if wallNanos > 0 {
                    cpu = Double(usage.cpuNanos - previous.nanos) / wallNanos * 100
                }
            }
            previousCPUNanos[pid] = (usage.cpuNanos, now)

            let project: String?
            if let cached = projectCache[pid] {
                project = cached
            } else {
                project = Self.projectRoot(cwd: Self.workingDirectory(of: pid), args: args)
                projectCache[pid] = project
            }

            let name: String
            if let cached = nameCache[pid] {
                name = cached
            } else {
                name = Self.displayName(args, ide: Self.owningIDE(of: pid))
                nameCache[pid] = name
            }

            // Workspace is ownership context, so it is only worth showing for
            // processes that have no project of their own.
            var workspace: String?
            if project == nil, let window = Self.ideAncestor(of: pid)?.pid {
                workspace = workspaceByWindow[window] ?? nil
            }

            next.append(DartProcess(
                id: pid,
                name: name,
                executableName: (args[0] as NSString).lastPathComponent,
                command: args.joined(separator: " "),
                projectPath: project,
                workspace: workspace,
                cpuPercent: cpu,
                memoryBytes: usage.footprintBytes
            ))
        }
        previousCPUNanos = previousCPUNanos.filter { seen.contains($0.key) }
        projectCache = projectCache.filter { seen.contains($0.key) }
        nameCache = nameCache.filter { seen.contains($0.key) }
        // Keyed to the daemon's lifetime, not to which rows happened to want it
        // this tick, so a cached answer is never dropped and re-fetched.
        workspaceByWindow = workspaceByWindow.filter { dtdByWindow[$0.key] != nil }

        let peakMemory = next.map(\.memoryBytes).max() ?? 0
        processes = next.sorted { lhs, rhs in
            let left = Self.loadScore(lhs, peakMemoryBytes: peakMemory)
            let right = Self.loadScore(rhs, peakMemoryBytes: peakMemory)
            // pid breaks ties so equally idle rows do not shuffle between ticks.
            return left == right ? lhs.id < rhs.id : left > right
        }
    }

    /// Ranks a process by how heavy it is on *either* axis, so a CPU-burning
    /// process rises without a large one having to also be memory-heavy.
    ///
    /// CPU is measured against one full core and memory against the heaviest
    /// process, matching the two bars: at idle every CPU term is near zero and
    /// the order degenerates to memory, which is the useful default.
    nonisolated static func loadScore(_ process: DartProcess, peakMemoryBytes: UInt64) -> Double {
        let cpu = min(process.cpuPercent / 100, 1)
        let memory = peakMemoryBytes > 0
            ? Double(process.memoryBytes) / Double(peakMemoryBytes)
            : 0
        return cpu + memory
    }

    /// Records a resolved workspace and refreshes rows so it appears without
    /// waiting for the next tick. Failures are cached as nil, not retried.
    private func storeWorkspace(_ root: String?, for window: pid_t) async {
        resolvingWindows.remove(window)
        workspaceByWindow[window] = root
        if root != nil { await sample() }
    }

    /// SIGTERM, then resample so the row disappears promptly. If the process
    /// is already gone the signal is a no-op and the next sample drops it.
    func terminate(_ pid: pid_t) {
        Darwin.kill(pid, SIGTERM)
        Task { await sample() }
    }

    // MARK: - Pure helpers (unit tested)

    nonisolated static func parse(psOutput: String) -> [(pid: pid_t, args: [String])] {
        psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { return nil }
            // ponytail: whitespace tokenisation splits paths containing spaces;
            // such fragments only ever become failed project-root candidates.
            let args = trimmed[trimmed.index(after: space)...]
                .split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard !args.isEmpty else { return nil }
            return (pid, args)
        }
    }

    /// Our own bundle as it appears in a ps argv.
    ///
    /// Matched against the joined arguments rather than `args.first`, because
    /// "Dart Radar.app" contains a space and `parse` tokenises on whitespace:
    /// argv[0] arrives as just "/Applications/Dart", whose last component is
    /// literally "dart" and so matches the runtime prefix test below. Keep this
    /// in step with PRODUCT_NAME in project.yml.
    private static let ownBundleMarker = "Dart Radar.app/Contents/MacOS/"

    nonisolated static func isDartRelated(_ args: [String]) -> Bool {
        guard let exe = args.first else { return false }
        // Our own app is called "Dart ..." too; never track a copy of ourselves.
        // The live instance is already excluded by pid, so what this catches is
        // a second copy, typically a Debug build running beside a release one.
        if args.joined(separator: " ").contains(ownBundleMarker) { return false }
        let base = (exe as NSString).lastPathComponent.lowercased()
        // Covers dart, dartvm, dartaotruntime, dart_mcp_server, plus puro and
        // anything launched straight out of a dart-sdk directory. Shell
        // wrappers (bash .../flutter run) are excluded on purpose: their dart
        // children are what actually consume resources.
        return base.hasPrefix("dart") || base == "puro" || base == "flutter_tester"
            || exe.contains("/dart-sdk/")
    }

    /// Value of `--flag=value` or `--flag value`.
    nonisolated static func flagValue(_ flag: String, _ args: [String]) -> String? {
        for (index, arg) in args.enumerated() {
            if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            if arg == flag, index + 1 < args.count, !args[index + 1].hasPrefix("-") {
                return args[index + 1]
            }
        }
        return nil
    }

    /// Human-readable role, parsed from the full argument vector.
    ///
    /// The executable name is almost never the identity: `dartvm` and
    /// `dartaotruntime` are generic runtimes whose real job is named by the
    /// .snapshot they execute, and `puro` is a version-manager shim that
    /// forwards to a real `flutter`/`dart` subcommand.
    nonisolated static func displayName(_ args: [String], ide: String? = nil) -> String {
        guard let exe = args.first else { return "Dart" }
        let base = (exe as NSString).lastPathComponent
        if base == "dart_mcp_server" { return "MCP Server" }

        let snapshot = args.dropFirst()
            .first { $0.hasSuffix(".snapshot") }
            .map { ($0 as NSString).lastPathComponent }

        if let snapshot, snapshot.hasPrefix("frontend_server") {
            // --target names the compilation target: dartdevc = web, flutter = native.
            switch flagValue("--target", args) {
            case "dartdevc": return "Frontend Compiler (web)"
            case "flutter": return "Frontend Compiler (Flutter)"
            case let target?: return "Frontend Compiler (\(target))"
            case nil: return "Frontend Compiler"
            }
        }
        if let snapshot, snapshot.hasPrefix("dds") {
            return decorated("Dart Dev Service", args)
        }

        // Tokens after the executable, and after the snapshot when one is run.
        var rest = Array(args.dropFirst())
        if let index = rest.firstIndex(where: { $0.hasSuffix(".snapshot") }) {
            rest = Array(rest[(index + 1)...])
        }
        var isFlutter = snapshot?.hasPrefix("flutter_tools") ?? false
        var subcommand: String?
        for token in rest where !token.hasPrefix("-") && !token.hasPrefix("/") {
            // `puro flutter daemon` / `puro dart mcp-server`: skip the shim's
            // tool selector, but remember which tool it chose.
            if token == "flutter" { isFlutter = true; continue }
            if token == "dart" { continue }
            subcommand = token
            break
        }

        switch subcommand {
        case "language-server", "analysis-server":
            // --client-id is the only thing distinguishing otherwise identical analyzers.
            let client = flagValue("--client-id", args)?
                .replacingOccurrences(of: "-", with: " ")
            return qualified("Analyzer", client ?? ide)
        case "tooling-daemon": return qualified("Tooling Daemon", ide)
        case "devtools": return qualified("DevTools", ide)
        case "mcp-server": return qualified("MCP Server", ide)
        case "development-service": return decorated("Dart Dev Service", args)
        case "daemon": return qualified(isFlutter ? "Flutter Daemon" : "Daemon", ide)
        case "run", "attach", "test", "drive":
            let verb = (isFlutter ? "Flutter " : "Dart ") + subcommand!.capitalized
            guard let device = flagValue("--device-id", args) ?? flagValue("-d", args),
                  device.count <= 24 else { return verb }  // skip raw simulator UUIDs
            return "\(verb) (\(device))"
        case let other?:
            // Unknown subcommand (pub, compile, format, build, …): show it verbatim
            // but capitalised, so it reads like the known ones rather than argv.
            return (isFlutter ? "Flutter " : "Dart ") + other.capitalized
        case nil:
            return isFlutter ? "Flutter" : (base == "puro" ? "Puro" : "Dart")
        }
    }

    /// Value of a flag whose value contains spaces, e.g.
    /// `--app-name=Kind: Flutter - Device: iPhone 17 Pro - Package: hyper_zones`.
    /// argv arrives whitespace-split, so rejoin until the next `--flag`.
    nonisolated static func spacedFlagValue(_ flag: String, _ args: [String]) -> String? {
        guard let start = args.firstIndex(where: { $0.hasPrefix(flag + "=") }) else { return nil }
        var parts = [String(args[start].dropFirst(flag.count + 1))]
        for token in args[(start + 1)...] {
            if token.hasPrefix("--") { break }
            parts.append(token)
        }
        return parts.joined(separator: " ")
    }

    /// Fields of a dev-service `--app-name`, e.g. ["Kind": "Flutter",
    /// "Device": "iPhone 17 Pro", "Package": "hyper_zones"].
    nonisolated static func appNameFields(_ args: [String]) -> [String: String] {
        guard let appName = spacedFlagValue("--app-name", args) else { return [:] }
        var fields: [String: String] = [:]
        // " - " rather than "-", so hyphenated device names survive.
        for field in appName.components(separatedBy: " - ") {
            let pair = field.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, !pair[1].isEmpty { fields[pair[0]] = pair[1] }
        }
        return fields
    }

    nonisolated static func qualified(_ name: String, _ qualifier: String?) -> String {
        guard let qualifier, !qualifier.isEmpty else { return name }
        return "\(name) (\(qualifier))"
    }

    /// DDS/dev-service processes name the device they are attached to.
    nonisolated static func decorated(_ name: String, _ args: [String]) -> String {
        guard let device = appNameFields(args)["Device"] else { return name }
        return "\(name) (\(device))"
    }

    /// Walks up from the process cwd (and any absolute-path arguments outside
    /// tooling directories) to the nearest directory containing pubspec.yaml.
    nonisolated static func projectRoot(
        cwd: String?,
        args: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        // Tooling paths are excluded everywhere: the Flutter SDK checkout has
        // its own pubspec.yaml, so an SDK cwd would otherwise "link" daemons
        // to the SDK instead of a user project.
        var candidates: [String] = []
        if let cwd, cwd != "/", !isToolingPath(cwd) { candidates.append(cwd) }

        // Only arguments AFTER the snapshot can name a user project. The ones
        // before it are VM bootstrap flags, and flutter_tools is launched with
        // `--packages=<SDK>/packages/flutter_tools/.dart_tool/package_config.json`
        // which otherwise resolves every flutter daemon to "flutter_tools" on
        // any SDK installed outside the tooling directories.
        var scannable = Array(args.dropFirst())
        if let snapshot = scannable.firstIndex(where: { $0.hasSuffix(".snapshot") }) {
            scannable = Array(scannable[(snapshot + 1)...])
        }
        candidates += scannable.filter { $0.hasPrefix("/") && !isToolingPath($0) }
        for candidate in candidates {
            var dir = candidate
            for _ in 0..<15 {
                if fileExists((dir as NSString).appendingPathComponent("pubspec.yaml")) {
                    return dir
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        // No pubspec found: a real cwd is still a useful place to link to.
        if let cwd, cwd != "/", cwd != NSHomeDirectory(), !isToolingPath(cwd) { return cwd }
        return nil
    }

    nonisolated static func isToolingPath(_ path: String) -> Bool {
        for marker in ["/.puro/", "/dart-sdk/", "/Library/", "/Applications/",
                       "/flutter/bin/", "/private/", "/var/", "/tmp/"]
        where path.contains(marker) { return true }
        return false
    }

    nonisolated static func memoryText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    // MARK: - System access

    nonisolated static func listProcesses() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated static func usage(of pid: pid_t) -> (cpuNanos: UInt64, footprintBytes: UInt64)? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        // ri_user_time / ri_system_time are in mach absolute-time units.
        let ticks = info.ri_user_time &+ info.ri_system_time
        let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return (nanos, info.ri_phys_footprint)
    }

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    nonisolated static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 * PATH_MAX); the macro is not exported to Swift.
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated static func ideName(_ executablePath: String) -> String? {
        // Ordered: Cursor and Windsurf are VS Code forks, so they must be
        // checked before the generic "Code Helper" match.
        let editors = [
            ("Cursor", "Cursor"), ("Windsurf", "Windsurf"),
            ("Visual Studio Code", "VS Code"), ("Code Helper", "VS Code"),
            ("Android Studio", "Android Studio"), ("IntelliJ", "IntelliJ"),
            ("Xcode", "Xcode"), ("Zed", "Zed"),
        ]
        return editors.first { executablePath.contains($0.0) }?.1
    }

    /// The editor process that spawned this one, found by walking the parent
    /// chain. The chain carries no project path (IDEs launched from Finder
    /// inherit cwd "/"), but it does reliably identify the owning editor.
    /// For VS Code the matched ancestor is the per-window extension host,
    /// which is precisely the granularity a DTD serves.
    nonisolated static func ideAncestor(of pid: pid_t) -> (pid: pid_t, name: String)? {
        var current = pid
        for _ in 0..<10 {
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            if let path = executablePath(of: parent), let ide = ideName(path) {
                return (parent, ide)
            }
            current = parent
        }
        return nil
    }

    nonisolated static func owningIDE(of pid: pid_t) -> String? { ideAncestor(of: pid)?.name }

    /// The `ws://127.0.0.1:<port>/<secret>` a `dart devtools` process was given.
    /// DevTools is the only process that carries the daemon's auth secret.
    nonisolated static func dtdURI(_ args: [String]) -> URL? {
        guard let value = flagValue("--dtd-uri", args), value.hasPrefix("ws") else { return nil }
        return URL(string: value)
    }

    nonisolated static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) > 0 else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            raw.withMemoryRebound(to: CChar.self) { String(cString: $0.baseAddress!) }
        }
    }

    private nonisolated static let timebase: mach_timebase_info_data_t = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return timebase
    }()

    /// `Dart Radar.app/Contents/MacOS/Dart Radar --dump` prints one live
    /// sample (with a real CPU delta) and exits. Smallest end-to-end check.
    nonisolated static func dumpOnce() {
        let output = listProcesses()
        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let all = parse(psOutput: output)
        let entries = all.filter { $0.pid != ownPID && isDartRelated($0.args) }

        // Resolve each editor window's workspace up front. Blocking is fine
        // here: this path is a one-shot terminal dump, not the live UI.
        var workspaces: [pid_t: String] = [:]
        for (pid, args) in all {
            guard let uri = dtdURI(args), let window = ideAncestor(of: pid)?.pid,
                  workspaces[window] == nil else { continue }
            let ready = DispatchSemaphore(value: 0)
            var root: String?
            Task {
                root = await WorkspaceResolver.workspaceRoot(dtd: uri)
                ready.signal()
            }
            _ = ready.wait(timeout: .now() + 5)
            if let root { workspaces[window] = root }
        }
        let first = entries.compactMap { entry in usage(of: entry.pid).map { (entry.pid, $0.cpuNanos) } }
        usleep(500_000)
        let baseline = Dictionary(uniqueKeysWithValues: first)
        for (pid, args) in entries {
            guard let usage = usage(of: pid) else { continue }
            var cpu = 0.0
            if let before = baseline[pid], usage.cpuNanos >= before {
                cpu = Double(usage.cpuNanos - before) / 0.5e9 * 100
            }
            let ancestor = ideAncestor(of: pid)
            let name = displayName(args, ide: ancestor?.name)
            let project = projectRoot(cwd: workingDirectory(of: pid), args: args)
            let location = project
                ?? ancestor.flatMap { workspaces[$0.pid] }.map { "workspace: \($0)" }
                ?? "-"
            print("\(pid)\t\(name)\t\(String(format: "%.1f%%", cpu))\t\(memoryText(usage.footprintBytes))\t\(location)")
        }
    }
}

/// System-wide memory, the numbers Activity Monitor's Memory tab shows.
struct SystemMemory: Equatable {
    var physical: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cachedFiles: UInt64 = 0
    var swapUsed: UInt64 = 0
    /// From the kernel: 1 normal, 2 warning, 4 critical.
    var pressureLevel: Int32 = 1

    var used: UInt64 { app + wired + compressed }

    /// Share of RAM the kernel cannot hand back on demand. Apple does not
    /// publish the formula behind the Memory Pressure graph, so this is the
    /// usual approximation, and it only drives the graph's height. The colour
    /// comes from `pressureLevel`, which is the kernel's own verdict.
    var pressure: Double {
        physical > 0 ? Double(wired + compressed) / Double(physical) : 0
    }

    static func sample() -> SystemMemory {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return SystemMemory() }

        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        var memory = SystemMemory()
        memory.physical = ProcessInfo.processInfo.physicalMemory
        memory.wired = UInt64(stats.wire_count) * page
        memory.compressed = UInt64(stats.compressor_page_count) * page
        memory.cachedFiles = (UInt64(stats.external_page_count) + purgeable) * page
        // Purgeable pages are counted as internal but are reclaimable, so
        // Activity Monitor excludes them from App Memory. Guarded rather than
        // subtracted directly: these are two independently sampled counters.
        memory.app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        memory.swapUsed = swapUsed()
        memory.pressureLevel = kernelPressureLevel()
        return memory
    }

    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    static func kernelPressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return 1 }
        return level
    }
}
