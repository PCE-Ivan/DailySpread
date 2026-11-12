import SwiftUI

@main
struct DailySpreadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(WallpaperController.shared)
                .environmentObject(Preferences.shared)
        } label: {
            MenuBarIcon()
                .environmentObject(WallpaperController.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            // The app only works while it's running, so open it at login unless the user has turned that off.
            let defaults = UserDefaults.standard
            if !defaults.bool(forKey: "didSetUpLoginItem") {
                defaults.set(true, forKey: "didSetUpLoginItem")
                try? LoginItem.set(true)
            }
            WallpaperController.shared.start()
            // `open DailySpread.app --args --new-wallpaper` fetches one straight away.
            if CommandLine.arguments.contains("--new-wallpaper") {
                await WallpaperController.shared.fetchNew()
            }
        }
    }
}
