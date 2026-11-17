import AppKit
import os

/// Writes to the system log whenever a NotchBead window takes or gives up the keyboard, or NotchBead
/// becomes or stops being the active app, so "my typing went nowhere" can be traced:
/// `log show --last 1h --predicate 'subsystem == "io.github.successcw.notchbead" && category == "focus"'`
@MainActor
enum FocusLog {
    private static let log = Logger(subsystem: "io.github.successcw.notchbead", category: "focus")
    private static var observers: [NSObjectProtocol] = []

    static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, String)] = [
            (NSWindow.didBecomeKeyNotification, "window took keyboard"),
            (NSWindow.didResignKeyNotification, "window gave up keyboard"),
            (NSApplication.didBecomeActiveNotification, "NotchBead became active app"),
            (NSApplication.didResignActiveNotification, "NotchBead stopped being active app"),
        ]
        for (name, what) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { notification in
                let window = (notification.object as? NSWindow).map { String(describing: type(of: $0)) } ?? "-"
                MainActor.assumeIsolated { FocusLog.note(what, window: window) }
            })
        }
    }

    static func note(_ what: String, window: String = "-") {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        log.notice("\(what, privacy: .public) window=\(window, privacy: .public) front=\(front, privacy: .public)")
    }
}
