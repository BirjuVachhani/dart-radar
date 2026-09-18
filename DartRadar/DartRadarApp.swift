import Sparkle
import SwiftUI

/// Sparkle's updater, as a lazily created global.
///
/// Deliberately not a stored property of `DartRadarApp`: stored properties are
/// initialised before `init` runs, and `init` exits the process outright in
/// `--dump` mode, so an updater held there would start a scheduled check and
/// tear it down again on every terminal dump. A `static let` is only built on
/// first use, which is the first time something asks to check for updates.
enum Updater {
    /// `startingUpdater: true` begins Sparkle's background schedule at once.
    /// The feed and the key that validates it come from Info.plist (SUFeedURL,
    /// SUPublicEDKey); see project.yml.
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
}

@main
struct DartRadarApp: App {
    @State private var monitor = ProcessMonitor()

    init() {
        if CommandLine.arguments.contains("--dump") {
            ProcessMonitor.dumpOnce()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ProcessListView()
                .environment(monitor)
                .frame(minWidth: 820, minHeight: 380)
        }
        .commands {
            // Sits under the app menu next to "About", where macOS users look
            // for it. The menu bar extra has its own button in the footer,
            // because that popover is the app's main surface.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Updater.shared.checkForUpdates(nil)
                }
            }
        }
        MenuBarExtra {
            ProcessListView(compact: true)
                .environment(monitor)
                .frame(width: 540, height: 470)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Separate view so the label re-renders when the observable monitor updates.
private struct MenuBarLabel: View {
    let monitor: ProcessMonitor

    var body: some View {
        Label(monitor.totalMemoryText, systemImage: "memorychip")
    }
}
