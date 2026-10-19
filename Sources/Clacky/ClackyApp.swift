import SwiftUI

@main
struct ClackyApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Clacky's colors are a dark palette, so it stays dark even when the Mac is in light mode.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(model: model)
        }
    }
}
