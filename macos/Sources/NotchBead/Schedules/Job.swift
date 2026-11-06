// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import Foundation

enum JobSource: String, Codable, Sendable {
    case launchd
    case cron
    case at
    case periodic
    case loginItem
    case automation
}

/// Where a task is defined, which decides who it runs as and what NotchBead may do with it.
enum JobLocation: String, Codable, Sendable {
    /// ~/Library/LaunchAgents
    case userAgent
    /// /Library/LaunchAgents: runs for every user, in your login session.
    case allUsersAgent
    /// /Library/LaunchDaemons: runs as root at startup.
    case daemon
    /// Loaded in your session by an app (SMAppService and the like), with no plist in a LaunchAgents folder.
    case appAgent
    /// Loaded as root by an app, with no plist in /Library/LaunchDaemons.
    case appDaemon
    case userCrontab
    /// /etc/crontab, which names the user each line runs as.
    case systemCrontab
    case atQueue
    case periodic
    /// System Settings › General › Login Items.
    case loginItem
    /// A scheduled prompt in the Codex app (~/.codex/automations).
    case codexAutomation
    /// A scheduled prompt in WorkBuddy.
    case workBuddyAutomation

    var tag: String {
        switch self {
        case .userAgent: "launchd"
        case .allUsersAgent: "all users"
        case .daemon: "root"
        case .appAgent: "app"
        case .appDaemon: "app · root"
        case .userCrontab: "cron"
        case .systemCrontab: "cron · root"
        case .atQueue: "at"
        case .periodic: "periodic"
        case .loginItem: "login"
        case .codexAutomation: "codex"
        case .workBuddyAutomation: "workbuddy"
        }
    }

    /// The app that runs it, for an automation.
    var appBundleID: String? {
        switch self {
        case .codexAutomation: ChatGPTAttention.bundleID
        case .workBuddyAutomation: WorkBuddyAttention.bundleID
        default: nil
        }
    }

    var runsAsRoot: Bool {
        switch self {
        case .daemon, .appDaemon, .systemCrontab, .periodic: true
        default: false
        }
    }

    /// The launchd domain its jobs live in.
    var launchdDomain: String? {
        switch self {
        case .userAgent, .allUsersAgent, .appAgent: Shell.guiDomain
        case .daemon, .appDaemon: "system"
        default: nil
        }
    }

    /// Run Now works without admin rights and without guessing how the task is set up.
    var canRun: Bool {
        switch self {
        case .userAgent, .allUsersAgent, .userCrontab: true
        default: false
        }
    }

    /// Pause and resume work in your own launchd session, from a plist NotchBead can reload.
    var canPause: Bool {
        switch self {
        case .userAgent, .allUsersAgent: true
        default: false
        }
    }

    /// Why the actions are missing, shown in place of them.
    var viewOnlyNote: String? {
        switch self {
        case .userAgent, .allUsersAgent, .userCrontab: nil
        case .daemon, .appDaemon: "Runs as root, so NotchBead only shows it. Changing it needs an admin."
        case .appAgent: "Its app manages it. Turn it off in Login Items in System Settings, or in the app."
        case .systemCrontab: "Set in /etc/crontab, which only an admin can change."
        case .atQueue: "A one-off job. Remove it with atrm in Terminal."
        case .periodic: "Run by macOS as root on its daily, weekly or monthly pass."
        case .loginItem: "Turn it on or off in Login Items in System Settings."
        case .codexAutomation: "Runs in the ChatGPT (Codex) app. Change or pause it there."
        case .workBuddyAutomation: "Runs in WorkBuddy. Change or pause it there."
        }
    }
}

/// One `StartCalendarInterval` entry. A nil field matches every value, as in launchd.
/// `weekday` uses launchd's numbering: 0 and 7 are Sunday.
struct CalendarSpec: Equatable, Sendable {
    var minute: Int?
    var hour: Int?
    var day: Int?
    var weekday: Int?
    var month: Int?
}

struct Schedule: Equatable, Sendable {
    var interval: Int?
    var calendar: [CalendarSpec] = []
    var cron: CronExpression?
    var keepAlive = false
    var runAtLoad = false
    var watchesPaths = false
    /// Loads at startup rather than at login: a daemon's RunAtLoad, or cron's @reboot.
    var atStartup = false
    /// An `at` job, which runs once.
    var once: Date?
    /// Opens when you log in: a login item.
    var atLogin = false
    /// Started by launchd when another program connects to it (MachServices, Sockets).
    var onDemand = false

    /// A launchd job with both an interval and calendar times runs on both, which is rarely intended.
    var hasOverlap: Bool { interval != nil && !calendar.isEmpty }

    /// The parts of the schedule an overlap depends on, so a "keep as is" lasts only until they change.
    var overlapFingerprint: String {
        let times = calendar.map { spec in
            [spec.month, spec.day, spec.weekday, spec.hour, spec.minute].map { $0.map(String.init) ?? "*" }.joined(separator: ":")
        }
        return "\(interval ?? 0)|" + times.joined(separator: ",")
    }
}

enum JobState: Equatable, Sendable {
    case running
    case succeeded
    case failed(exitCode: Int32)
    case paused
    case waiting
}

struct RunRecord: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Date
    var end: Date?
    var exitCode: Int32?
    /// False when the run started and ended between two polls, so only the end time is known.
    var durationKnown = true

    var duration: TimeInterval? {
        guard durationKnown, let end else { return nil }
        return end.timeIntervalSince(start)
    }
}

struct Job: Identifiable, Equatable, Sendable {
    var id: String
    var source: JobSource
    var location: JobLocation = .userAgent
    var label: String
    var name: String
    var schedule: Schedule
    var arguments: [String]
    var plistURL: URL?
    var cronLine: String?
    /// For cron: the exact command text after the schedule, kept byte for byte.
    var cronCommand: String?
    /// For cron: the variables cron would set, so Run Now matches a real run.
    var cronEnvironment: [String: String] = [:]
    /// For /etc/crontab: the user the line runs as.
    var runsAs: String?
    /// For launchd: the folder it runs in.
    var workingDirectory: String?
    /// From Login Items: who made it, and whether it's allowed to run in the background.
    var developer: String?
    var backgroundAllowed: Bool?
    var stdoutPath: String?
    var stderrPath: String?
    var state: JobState = .waiting
    var pid: Int32?
    var lastExitCode: Int32?
    var totalRuns: Int?
    var lastRun: Date?
    /// Set by the scanner for vendor and app-bundled jobs; the user can override it.
    var looksSystemOwned = false
    var isHidden = false
    /// Kept at the top of the list, in its own group: the person's own tasks.
    var isPinned = false
    /// The person looked at this schedule's overlap and kept it on purpose.
    var overlapAccepted = false

    /// An overlap still worth a look: one nobody has said is intended.
    var flagsOverlap: Bool { schedule.hasOverlap && !overlapAccepted }

    var isAlwaysOn: Bool { schedule.keepAlive }

    var logPath: String? { stdoutPath ?? stderrPath }

    var commandLine: String {
        if source == .cron, let command = cronCommand ?? arguments.last { return command }
        return arguments.joined(separator: " ")
    }
}
