import SwiftUI

@main
struct NightShifterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var controller = RampController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
        } label: {
            Image(systemName: iconName)
        }
        // .window gives a real panel rather than an NSMenu, which is what lets the curve and the
        // sliders live in the dropdown at all.
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        guard Settings.shared.engaged else { return "sun.max" }
        return controller.currentStrength > 0.001 ? "moon.fill" : "sun.horizon"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Settings.shared.engaged { RampController.shared.engage() }
    }

    // Leaving the user's Night Shift mode set to .off after we quit would silently strip their
    // schedule, so always hand it back.
    func applicationWillTerminate(_ notification: Notification) {
        RampController.shared.disengage()
    }
}
