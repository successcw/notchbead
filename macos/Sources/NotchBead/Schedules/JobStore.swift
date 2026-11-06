// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import AppKit
import Observation
import ServiceManagement

enum OverallState: Equatable {
    case empty
    case ok
    case running
    case headsUp
    case failed
}

@MainActor
@Observable
final class JobStore {
    private(set) var jobs: [Job] = []
    private(set) var lastUpdated: Date?
    private(set) var isRefreshing = false
    var showHidden = false

    @ObservationIgnored let history = RunHistory()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private var userHidden: Set<String>
    private var userPinned: Set<String>
    /// Tasks that would be pinned on their own but the person unpinned.
    private var userUnpinned: Set<String>
    private var userShown: Set<String>
    /// Job IDs whose overlap was kept on purpose, each with the schedule it was kept for.
    private var acceptedOverlaps: [String: String]

    private static let pollInterval: Duration = .seconds(10)
    private static let hiddenKey = "hiddenJobs"
    private static let shownKey = "shownJobs"
    private static let pinnedKey = "pinnedJobs"
    private static let unpinnedKey = "unpinnedJobs"
    private static let acceptedOverlapsKey = "acceptedOverlaps"

    init() {
        let defaults = UserDefaults.standard
        userHidden = Set(defaults.stringArray(forKey: Self.hiddenKey) ?? [])
        userShown = Set(defaults.stringArray(forKey: Self.shownKey) ?? [])
        userPinned = Set(defaults.stringArray(forKey: Self.pinnedKey) ?? [])
        userUnpinned = Set(defaults.stringArray(forKey: Self.unpinnedKey) ?? [])
        acceptedOverlaps = defaults.dictionary(forKey: Self.acceptedOverlapsKey) as? [String: String] ?? [:]
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh()
            await self?.backfillFromSystemLog()
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func refresh() async {
        isRefreshing = true
        let scanned = await Task.detached(priority: .utility) {
            (LaunchdScanner.scan() + CronScanner.scan() + CodexAutomations.scan() + WorkBuddyAutomations.scan(),
             LaunchdScanner.disabledLabels(domain: Shell.guiDomain))
        }.value
        // Only what you set up yourself, or had Codex or WorkBuddy set up for you.
        let merged = scanned.0.filter(Self.looksLikeYours)

        var updated = merged.map { job in
            var job = job
            job.isHidden = userHidden.contains(job.id) || (job.looksSystemOwned && !userShown.contains(job.id))
            job.overlapAccepted = acceptedOverlaps[job.id] == job.schedule.overlapFingerprint
            job.isPinned = userPinned.contains(job.id)
            return job
        }
        history.observe(updated.filter { !$0.isHidden })
        updated = updated.map(applyHistory)

        jobs = updated
        lastUpdated = .now
        isRefreshing = false
    }

    private func backfillFromSystemLog() async {
        let candidates = jobs.filter { $0.source == .launchd && $0.location.launchdDomain == Shell.guiDomain && !$0.isHidden && !$0.isAlwaysOn && history.records(for: $0.id).isEmpty }
        let labels = Set(candidates.map(\.label))
        guard !labels.isEmpty else { return }
        let ends = await Task.detached(priority: .background) { LaunchdLog.recentRunEnds(for: labels) }.value
        for job in candidates {
            history.backfill(jobID: job.id, ends: ends[job.label] ?? [], lastExitCode: job.lastExitCode)
        }
        jobs = jobs.map(applyHistory)
    }

    private func applyHistory(_ job: Job) -> Job {
        var job = job
        let records = history.records(for: job.id)
        job.lastRun = records.last.map { $0.end ?? $0.start } ?? RunHistory.lastLogWrite(for: job)
        return job
    }

    // MARK: - Derived state

    var visibleJobs: [Job] {
        let now = Date.now
        return jobs
            .filter { showHidden || !$0.isHidden }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                let left = sortRank(lhs), right = sortRank(rhs)
                if left != right { return left < right }
                let leftNext = nextRun(for: lhs, now: now) ?? .distantFuture
                let rightNext = nextRun(for: rhs, now: now) ?? .distantFuture
                if leftNext != rightNext { return leftNext < rightNext }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private var activeJobs: [Job] { jobs.filter { !$0.isHidden } }

    var hiddenCount: Int { jobs.filter(\.isHidden).count }
    var activeCount: Int { activeJobs.count }
    var overlapCount: Int { activeJobs.filter(\.flagsOverlap).count }
    /// Running jobs that will finish, as opposed to always-on ones.
    var activeRunCount: Int { activeJobs.filter { $0.state == .running && !$0.isAlwaysOn }.count }
    var failedCount: Int { activeJobs.filter { if case .failed = $0.state { true } else { false } }.count }
    var runningCount: Int { activeJobs.filter { $0.state == .running }.count }

    var overallState: OverallState {
        let active = activeJobs
        if active.isEmpty { return .empty }
        if failedCount > 0 { return .failed }
        if active.contains(where: \.flagsOverlap) { return .headsUp }
        if active.contains(where: { $0.state == .running && !$0.isAlwaysOn }) { return .running }
        return .ok
    }

    func job(id: String) -> Job? {
        jobs.first { $0.id == id }
    }

    func nextRun(for job: Job, now: Date) -> Date? {
        guard job.state != .paused else { return nil }
        return ScheduleText.nextRun(for: job.schedule, lastRun: job.lastRun, after: now)
    }

    func nextUp(now: Date) -> (job: Job, date: Date)? {
        activeJobs
            .compactMap { job in nextRun(for: job, now: now).map { (job, $0) } }
            .min { $0.1 < $1.1 }
    }

    func runningSince(_ job: Job) -> Date? {
        guard job.state == .running else { return nil }
        return history.records(for: job.id).last { $0.end == nil }?.start
    }

    func records(for job: Job) -> [RunRecord] {
        history.records(for: job.id)
    }

    /// How many of the most recent runs failed back to back.
    func failureStreak(for job: Job) -> Int {
        var streak = 0
        for record in history.records(for: job.id).reversed() {
            guard let code = record.exitCode, code != 0 else { break }
            streak += 1
        }
        if case .failed = job.state { return max(streak, 1) }
        return streak
    }

    func lastSuccess(for job: Job) -> Date? {
        history.records(for: job.id).last { $0.exitCode == 0 }.map { $0.end ?? $0.start }
    }

    private func sortRank(_ job: Job) -> Int {
        switch job.state {
        case .failed: 0
        case .running where !job.isAlwaysOn: 1
        case .paused: 4
        default: job.flagsOverlap ? 2 : 3
        }
    }

    // MARK: - Actions

    func runNow(_ job: Job) async {
        guard job.location.canRun else { return }
        switch job.source {
        case .launchd:
            guard let domain = job.location.launchdDomain else { return }
            let target = "\(domain)/\(job.label)"
            let plistPath = job.plistURL?.path
            await Task.detached {
                if Shell.launchctl("kickstart", target).status != 0, let plistPath {
                    Shell.launchctl("bootstrap", domain, plistPath)
                    Shell.launchctl("kickstart", target)
                }
            }.value
        case .cron:
            let command = job.cronCommand ?? job.commandLine
            let environment = CronScanner.environment(for: job)
            await Task.detached { Shell.runLikeCron(command, environment: environment) }.value
        default:
            return
        }
        try? await Task.sleep(for: .seconds(1))
        await refresh()
    }

    func setPaused(_ job: Job, paused: Bool) async {
        guard job.location.canPause, let domain = job.location.launchdDomain, let plistPath = job.plistURL?.path else { return }
        let target = "\(domain)/\(job.label)"
        await Task.detached {
            if paused {
                Shell.launchctl("disable", target)
                Shell.launchctl("bootout", target)
            } else {
                Shell.launchctl("enable", target)
                Shell.launchctl("bootstrap", domain, plistPath)
            }
        }.value
        await refresh()
    }

    /// Yours: a Codex or WorkBuddy automation, any entry in your own crontab, or one of your own
    /// launchd agents whose program, script or working folder is in your home folder (outside
    /// ~/Library and hidden folders), or that is named after you ("com.<your user name>.backup").
    /// Agents that apps install, like updaters, run from /Applications or ~/Library and stay out.
    static func looksLikeYours(_ job: Job) -> Bool {
        switch job.location {
        case .codexAutomation, .workBuddyAutomation, .userCrontab:
            return true
        case .userAgent:
            if job.label.lowercased().hasPrefix("com.\(NSUserName().lowercased()).") { return true }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            func inHome(_ path: String?) -> Bool {
                guard let path else { return false }
                let full = (path as NSString).expandingTildeInPath
                return full.hasPrefix(home + "/") && !full.hasPrefix(home + "/Library/") && !full.hasPrefix(home + "/.")
            }
            return inHome(JobNaming.scriptPath(in: job.arguments)) || inHome(job.arguments.first) || inHome(job.workingDirectory)
        default:
            return false
        }
    }

    func setPinned(_ job: Job, pinned: Bool) {
        if pinned {
            userPinned.insert(job.id)
            userUnpinned.remove(job.id)
        } else {
            userPinned.remove(job.id)
            if Self.looksLikeYours(job) { userUnpinned.insert(job.id) }
        }
        let defaults = UserDefaults.standard
        defaults.set(Array(userPinned), forKey: Self.pinnedKey)
        defaults.set(Array(userUnpinned), forKey: Self.unpinnedKey)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].isPinned = pinned }
    }

    func setHidden(_ job: Job, hidden: Bool) {
        if hidden {
            userHidden.insert(job.id)
            userShown.remove(job.id)
        } else {
            userHidden.remove(job.id)
            if job.looksSystemOwned { userShown.insert(job.id) }
        }
        let defaults = UserDefaults.standard
        defaults.set(Array(userHidden), forKey: Self.hiddenKey)
        defaults.set(Array(userShown), forKey: Self.shownKey)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].isHidden = hidden }
    }

    /// Keeps an overlapping schedule as it is. If the schedule changes, NotchBead asks again.
    func setOverlapAccepted(_ job: Job, accepted: Bool) {
        if accepted {
            acceptedOverlaps[job.id] = job.schedule.overlapFingerprint
        } else {
            acceptedOverlaps[job.id] = nil
        }
        UserDefaults.standard.set(acceptedOverlaps, forKey: Self.acceptedOverlapsKey)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) { jobs[index].overlapAccepted = accepted }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openLog(_ job: Job) {
        guard let path = job.logPath else { return }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let console = URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open([url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealDefinition(_ job: Job) {
        if let url = job.plistURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
