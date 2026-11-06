import SwiftUI

@main
struct NotchBeadApp: App {
    @State private var store: AttentionStore
    @State private var display: DisplayController
    @State private var menuBead: MenuBarBead
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let store = AttentionStore()
        let jobs = JobStore()
        let display = DisplayController(store: store, jobs: jobs)
        store.start()
        jobs.start()
        // The notch window needs NSApp, which isn't ready until the app finishes launching.
        DispatchQueue.main.async { display.start() }
        _store = State(initialValue: store)
        _display = State(initialValue: display)
        let menuBead = MenuBarBead()
        menuBead.follow(store)
        _menuBead = State(initialValue: menuBead)
    }

    var body: some Scene {
        // Only when there's no notch to live in, and only while something needs you.
        MenuBarExtra(isInserted: Binding(get: { display.showsMenuBarIcon && !store.visible.isEmpty }, set: { _ in })) {
            PanelView(store: store, onOpen: { store.open($0) })
                .frame(width: 340)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: menuBead.mood, pose: menuBead.pose))
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Opening NotchBead again while it runs (from Spotlight, Finder or the Dock) brings up the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { DashboardWindow.shared.show() }
        return false
    }
}
