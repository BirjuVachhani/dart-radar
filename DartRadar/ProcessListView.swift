import AppKit
import SwiftUI

/// Shared column widths, so the table header and the rows cannot drift apart.
private enum Column {
    static func icon(_ compact: Bool) -> CGFloat { compact ? 14 : 18 }
    static func pid(_ compact: Bool) -> CGFloat { compact ? 42 : 52 }
    static func bar(_ compact: Bool) -> CGFloat {
        // Ten squares plus the nine gaps between them.
        let side: CGFloat = compact ? 3 : 4
        return side * 10 + 1.5 * 9
    }
    static func cpu(_ compact: Bool) -> CGFloat { compact ? 46 : 56 }
    static func memory(_ compact: Bool) -> CGFloat { compact ? 66 : 76 }
    static let action: CGFloat = 16
    static let spacing: CGFloat = 8
    /// Between a bar and its own value: they read as one reading.
    static let barGap: CGFloat = 4
    /// Between the CPU and Memory columns: they read as separate ones.
    static let group: CGFloat = 24
}

/// Ten segments of two stacked squares, filled left to right and shaded
/// green through red, so load is readable at a glance.
struct UsageBar: View {
    let fraction: Double
    var compact = false

    /// Anything non-zero lights at least one square, so a live process is never
    /// rendered as an empty bar, and rounding can never overflow the ten.
    static func filledSegments(for fraction: Double) -> Int {
        guard fraction > 0, fraction.isFinite else { return 0 }
        return max(1, min(10, Int((fraction * 10).rounded())))
    }

    private func color(at index: Int) -> Color {
        switch index {
        case 0..<4: .green
        case 4..<7: .yellow
        case 7..<9: .orange
        default: .red
        }
    }

    var body: some View {
        let side: CGFloat = compact ? 3 : 4
        let filled = Self.filledSegments(for: fraction)
        HStack(spacing: 1.5) {
            ForEach(0..<10, id: \.self) { segment in
                VStack(spacing: 1.5) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(segment < filled
                                  ? color(at: segment)
                                  : Color.secondary.opacity(0.2))
                            .frame(width: side, height: side)
                    }
                }
            }
        }
        .frame(width: Column.bar(compact), alignment: .leading)
        .accessibilityLabel("\(Int(fraction * 100)) percent")
    }
}

struct ProcessListView: View {
    @Environment(ProcessMonitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    // AppStorage so the main window and menubar popup stay in sync.
    @AppStorage("hideProjectPaths") private var hideProjectPaths = false
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            header
            statsBar
            Divider()
            if monitor.processes.isEmpty {
                ContentUnavailableView(
                    "No Dart Processes",
                    systemImage: "moon.zzz",
                    description: Text("Dart VMs, analyzers, and Flutter tools will appear here.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    // A Section header inherits the list's row insets, so the
                    // column labels line up with the rows without hand-tuning.
                    Section {
                        ForEach(monitor.processes) { row($0) }
                    } header: {
                        tableHeader
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.enabled)
            }
            if compact {
                Divider()
                footer
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "memorychip")
                .foregroundStyle(.teal)
            Text("Dart Processes")
                .font(compact ? .headline : .title3.bold())
            Spacer()
            // Main window only: the panel needs more width than the menu bar
            // popup has, and the popup already shows totals below.
            if !compact {
                MemoryPanel(memory: monitor.memory, history: monitor.pressureHistory)
            }
            Button {
                hideProjectPaths.toggle()
            } label: {
                Image(systemName: hideProjectPaths ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(hideProjectPaths ? "Show project paths" : "Hide project paths")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, compact ? 8 : 10)
    }

    private var statsBar: some View {
        HStack(spacing: compact ? 16 : 28) {
            stat("Processes", "\(monitor.processes.count)")
            stat("Total CPU", String(format: "%.1f%%", monitor.totalCPUPercent))
            stat("Total Memory", monitor.totalMemoryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, compact ? 8 : 10)
    }

    private var tableHeader: some View {
        HStack(spacing: Column.spacing) {
            Color.clear.frame(width: Column.icon(compact), height: 0)
            // Labels sit at each column's starting edge, including the numeric
            // ones, whose values are right-aligned within the same box.
            Text("PID").frame(width: Column.pid(compact), alignment: .leading)
            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Column.group) {
                Text("CPU")
                    .frame(width: Column.bar(compact) + Column.barGap + Column.cpu(compact),
                           alignment: .leading)
                Text("Memory")
                    .frame(width: Column.bar(compact) + Column.barGap + Column.memory(compact),
                           alignment: .leading)
            }
            Color.clear.frame(width: Column.action, height: 0)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(compact ? .callout.bold() : .title3.bold())
                .monospacedDigit()
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate()
            }
            Spacer()
            Button("Check for Updates") { Updater.shared.checkForUpdates(nil) }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row(_ process: DartProcess) -> some View {
        HStack(spacing: Column.spacing) {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.teal)
                .font(compact ? .caption : .body)
                .frame(width: Column.icon(compact))
            Text(String(process.id))
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: Column.pid(compact), alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name)
                    .font(compact ? .caption : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(process.command)
                HStack(spacing: 4) {
                    // The OS-level name, kept visible because the label above is
                    // a parsed interpretation and this is the ground truth.
                    Text(process.executableName)
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.tertiary)
                    if let path = process.projectPath {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [URL(fileURLWithPath: path)]
                            )
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text(process.projectName ?? path)
                                    .fontWeight(.medium)
                                // Full-strength: inside a .link button, a
                                // .secondary path renders as a muted blue-grey
                                // that is hard to read at caption size.
                                Text(process.projectDisplayPath ?? path)
                                    .foregroundStyle(.primary)
                                    .truncationMode(.middle)
                                    .redacted(reason: hideProjectPaths ? .placeholder : [])
                            }
                            .font(compact ? .caption2 : .caption)
                            .lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .help(hideProjectPaths ? "" : path)
                    } else if let workspace = process.workspace {
                        // Not a project link: this process serves a whole editor
                        // window, so the workspace is shown as ownership only.
                        HStack(spacing: 4) {
                            Image(systemName: "macwindow")
                            Text((workspace as NSString).lastPathComponent)
                            Text((workspace as NSString).abbreviatingWithTildeInPath)
                                .truncationMode(.middle)
                                .redacted(reason: hideProjectPaths ? .placeholder : [])
                        }
                        .font(compact ? .caption2 : .caption)
                        // Still subordinate to a real project link, but legible:
                        // .tertiary was fainter again than the path above.
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(hideProjectPaths ? "" : "IDE workspace that owns this process: \(workspace)")
                    }
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: Column.group) {
                HStack(spacing: Column.barGap) {
                    // CPU is scaled against one full core, not against the other
                    // rows: at idle the busiest process is still idle, and showing
                    // it as a full bar would invent load that is not there.
                    UsageBar(fraction: process.cpuPercent / 100, compact: compact)
                    // Leading, not trailing: a right-aligned value drifts away
                    // from its bar by however short the number happens to be.
                    Text(String(format: "%.1f%%", process.cpuPercent))
                        .frame(width: Column.cpu(compact), alignment: .leading)
                        .foregroundStyle(process.cpuPercent >= 50 ? .orange : .primary)
                }
                HStack(spacing: Column.barGap) {
                    // Memory is scaled against the heaviest process, because the
                    // useful question is which of these is eating the most.
                    UsageBar(
                        fraction: monitor.peakMemoryBytes > 0
                            ? Double(process.memoryBytes) / Double(monitor.peakMemoryBytes)
                            : 0,
                        compact: compact
                    )
                    Text(ProcessMonitor.memoryText(process.memoryBytes))
                        .frame(width: Column.memory(compact), alignment: .leading)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                monitor.terminate(process.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: Column.action)
            .help("Quit process (SIGTERM)")
        }
        .font(compact ? .caption : .callout)
        .monospacedDigit()
    }
}

/// Filled pressure history, newest on the right, stretched to fill the width
/// so it reads at launch instead of after two minutes of samples.
struct PressureGraph: View {
    let samples: [Double]
    let color: Color
    var capacity = ProcessMonitor.historyLength

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let points = Array(samples.suffix(capacity))
            let step = size.width / CGFloat(max(points.count - 1, 1))
            let point = { (index: Int, value: Double) in
                CGPoint(x: CGFloat(index) * step,
                        y: size.height - CGFloat(min(max(value, 0), 1)) * size.height)
            }
            if points.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    for (index, value) in points.enumerated() {
                        path.addLine(to: point(index, value))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.35))
                // Separate open path: stroking the filled area would outline
                // its bottom and sides too.
                Path { path in
                    for (index, value) in points.enumerated() {
                        if index == 0 {
                            path.move(to: point(index, value))
                        } else {
                            path.addLine(to: point(index, value))
                        }
                    }
                }
                .stroke(color, lineWidth: 1)
            }
        }
        .background(alignment: .top) {
            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
        }
        .accessibilityLabel("Memory pressure \(Int((samples.last ?? 0) * 100)) percent")
    }
}

/// System memory at a glance, modelled on Activity Monitor's Memory tab.
struct MemoryPanel: View {
    let memory: SystemMemory
    let history: [Double]

    private var pressureColor: Color {
        switch memory.pressureLevel {
        case 4: .red
        case 2: .yellow
        default: .green
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Memory Pressure")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                PressureGraph(samples: history, color: pressureColor)
                    .frame(width: 118, height: 30)
            }
            .padding(.horizontal, 10)
            Divider()
            column(labelWidth: 92) {
                row("Physical Memory", memory.physical)
                row("Memory Used", memory.used)
                row("Cached Files", memory.cachedFiles)
                row("Swap Used", memory.swapUsed)
            }
            Divider()
            column(labelWidth: 80) {
                row("App Memory", memory.app)
                row("Wired Memory", memory.wired)
                row("Compressed", memory.compressed)
            }
        }
        .fixedSize()
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func column<Content: View>(
        labelWidth: CGFloat, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            content()
        }
        .font(.caption2)
        .environment(\.labelWidth, labelWidth)
        .padding(.horizontal, 10)
    }

    private func row(_ label: String, _ bytes: UInt64) -> some View {
        MemoryRow(label: label, value: ProcessMonitor.memoryText(bytes))
    }
}

private struct MemoryRow: View {
    @Environment(\.labelWidth) private var labelWidth
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
        }
    }
}

private struct LabelWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 90
}

extension EnvironmentValues {
    var labelWidth: CGFloat {
        get { self[LabelWidthKey.self] }
        set { self[LabelWidthKey.self] = newValue }
    }
}
