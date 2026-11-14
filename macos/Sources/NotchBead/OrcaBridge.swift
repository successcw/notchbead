import Foundation
import notify

/// Listens to the NotchBead bridge plugin for Orca (macos/OrcaPlugin). The plugin posts a Darwin
/// notification whenever an agent's status or the focused workspace changes, and touches a file
/// whenever it runs. While that file is recent, NotchBead checks Orca when told to plus a slow
/// safety check, instead of starting the Orca CLI (most of a second of CPU) every 3 seconds.
/// Without the plugin nothing changes.
@MainActor
final class OrcaBridge {
    static let changed = "com.notchbead.orca.changed"
    /// Touched by the plugin when its worker starts and on every change it reports.
    nonisolated static let seenFile = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/NotchBead/orca-bridge-seen")
    /// Orca stops an idle worker, so the plugin can be quiet for hours while still installed; if it
    /// was removed, Orca reminders are at worst 30 seconds late until this runs out.
    nonisolated static let trustFor: TimeInterval = 12 * 3600

    /// notify.h's NOTIFY_TOKEN_INVALID, which Swift doesn't import.
    private static let noToken: Int32 = -1
    private var changeToken = OrcaBridge.noToken

    /// `onChange` runs on the main queue for each notification.
    func start(onChange: @escaping @MainActor () -> Void) {
        guard changeToken == Self.noToken else { return }
        notify_register_dispatch(Self.changed, &changeToken, .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    /// Whether the plugin has run recently, so its notifications can be counted on.
    var isAlive: Bool {
        let seen = (try? FileManager.default.attributesOfItem(atPath: Self.seenFile.path))?[.modificationDate] as? Date
        return Self.isTrusted(seen: seen, now: .now)
    }

    nonisolated static func isTrusted(seen: Date?, now: Date) -> Bool {
        guard let seen else { return false }
        let age = now.timeIntervalSince(seen)
        // A little slack the other way, in case the two clocks were read a moment apart.
        return age > -60 && age < trustFor
    }
}
