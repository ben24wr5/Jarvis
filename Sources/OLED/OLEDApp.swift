import SwiftUI
import AppKit

@main
struct OLEDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("OLED") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)

        Settings {
            SettingsView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var logURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/OLED", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-problem.txt")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // If anything ever goes badly wrong, write down why, so it can be fixed.
        NSSetUncaughtExceptionHandler { exception in
            let text = "\(Date())\n\(exception.name.rawValue): \(exception.reason ?? "")\n\(exception.callStackSymbols.prefix(25).joined(separator: "\n"))\n"
            try? text.write(to: AppDelegate.logURL, atomically: true, encoding: .utf8)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyKeyCleanup.run() // OLED no longer uses an API key; remove any saved by older versions
        // Start OLED automatically when the Mac turns on (on by default; switch in Settings).
        if UserDefaults.standard.object(forKey: LaunchAtLogin.key) == nil {
            UserDefaults.standard.set(true, forKey: LaunchAtLogin.key)
        }
        LaunchAtLogin.apply()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeStore.shared

    var body: some View {
        Group {
            if app.setupDone {
                MainView()
            } else {
                SetupView()
            }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .id(theme.current.id) // redraw the whole window in the new theme straight away
    }
}
