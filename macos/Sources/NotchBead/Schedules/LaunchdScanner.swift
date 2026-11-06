// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import Foundation

/// Finds every launchd job that isn't part of macOS: the plists in the three LaunchAgents and
/// LaunchDaemons folders, plus jobs apps load from elsewhere, and asks launchctl how each is doing.
enum LaunchdScanner {
    static var agentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    static let allUsersAgentsDirectory = URL(fileURLWithPath: "/Library/LaunchAgents")
    static let daemonsDirectory = URL(fileURLWithPath: "/Library/LaunchDaemons")

    static func scan() -> [Job] {
        let guiLoaded = loadedJobs()
        let systemLoaded = parseServices(Shell.launchctl("print", "system").output)
        let guiDisabled = disabledLabels(domain: Shell.guiDomain)
        let systemDisabled = disabledLabels(domain: "system")

        var jobs: [Job] = []
        let folders: [(URL, JobLocation)] = [
            (agentsDirectory, .userAgent),
            (allUsersAgentsDirectory, .allUsersAgent),
            (daemonsDirectory, .daemon),
        ]
        for (folder, location) in folders {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let isSystem = location == .daemon
            for file in files where file.pathExtension == "plist" {
                guard var job = parse(plistAt: file, location: location) else { continue }
                let loaded = (isSystem ? systemLoaded : guiLoaded)[job.label]
                let disabled = (isSystem ? systemDisabled : guiDisabled).contains(job.label)
                applyStatus(to: &job, loaded: loaded, disabled: disabled)
                jobs.append(job)
            }
        }

        // Jobs launchd has loaded that no folder above accounts for: app helpers and the like.
        var known = Set(jobs.map(\.id))
        for (domain, loaded, location) in [(Shell.guiDomain, guiLoaded, JobLocation.appAgent), ("system", systemLoaded, .appDaemon)] {
            for label in loaded.keys.sorted() where isCandidate(label) {
                let id = jobID(label: label, location: location)
                // The id is the same as for a plist in the folders above, so those are skipped here.
                guard !known.contains(id),
                      var job = loadedOnlyJob(label: label, domain: domain, location: location)
                else { continue }
                known.insert(id)
                applyStatus(to: &job, loaded: loaded[label], disabled: false)
                jobs.append(job)
            }
        }
        return jobs
    }

    static func jobID(label: String, location: JobLocation) -> String {
        switch location {
        case .daemon, .appDaemon: "launchd-system:\(label)"
        default: "launchd:\(label)"
        }
    }

    /// Running apps show up in launchctl as "application.<bundle id>.<numbers>"; they aren't tasks.
    static func isCandidate(_ label: String) -> Bool {
        !label.hasPrefix("com.apple.") && !label.hasPrefix("application.")
    }

    static func parse(plistAt url: URL, location: JobLocation = .userAgent) -> Job? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String
        else { return nil }

        var arguments = plist["ProgramArguments"] as? [String] ?? []
        if let program = plist["Program"] as? String {
            if arguments.isEmpty { arguments = [program] } else { arguments[0] = program }
        }

        var schedule = Schedule()
        schedule.interval = plist["StartInterval"] as? Int
        if let dict = plist["StartCalendarInterval"] as? [String: Any] {
            schedule.calendar = [calendarSpec(dict)]
        } else if let list = plist["StartCalendarInterval"] as? [[String: Any]] {
            schedule.calendar = list.map(calendarSpec)
        }
        if let keepAlive = plist["KeepAlive"] as? Bool {
            schedule.keepAlive = keepAlive
        } else if plist["KeepAlive"] is [String: Any] {
            schedule.keepAlive = true
        }
        schedule.runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        schedule.watchesPaths = plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil
        schedule.atStartup = location.runsAsRoot
        schedule.onDemand = plist["MachServices"] != nil || plist["Sockets"] != nil

        var job = Job(
            id: jobID(label: label, location: location),
            source: .launchd,
            location: location,
            label: label,
            name: JobNaming.name(forLabel: label),
            schedule: schedule,
            arguments: arguments,
            plistURL: url,
            stdoutPath: plist["StandardOutPath"] as? String,
            stderrPath: plist["StandardErrorPath"] as? String
        )
        job.runsAs = plist["UserName"] as? String
        job.workingDirectory = plist["WorkingDirectory"] as? String
        job.looksSystemOwned = looksSystemOwned(label: label, program: arguments.first)
        if plist["Disabled"] as? Bool == true { job.state = .paused }
        return job
    }

    /// Only macOS's own jobs are hidden by default. Everything else that starts on its own is shown.
    static func looksSystemOwned(label: String, program: String?) -> Bool {
        if label.hasPrefix("com.apple.") { return true }
        guard let program else { return false }
        return program.hasPrefix("/System/") || program.hasPrefix("/usr/libexec/") || program.hasPrefix("/usr/sbin/")
    }

    private static func calendarSpec(_ dict: [String: Any]) -> CalendarSpec {
        CalendarSpec(
            minute: dict["Minute"] as? Int,
            hour: dict["Hour"] as? Int,
            day: dict["Day"] as? Int,
            weekday: dict["Weekday"] as? Int,
            month: dict["Month"] as? Int
        )
    }

    // MARK: - Jobs without a plist in the usual folders

    /// Builds a job from `launchctl print`. Returns nil for macOS's own jobs and for jobs that
    /// a program submitted only while it runs (an updater's helper, say), which don't start on their own.
    static func loadedOnlyJob(label: String, domain: String, location: JobLocation) -> Job? {
        let info = parsePrint(Shell.launchctl("print", "\(domain)/\(label)").output)
        if let path = info.path, path.hasPrefix("/System/") { return nil }

        var job: Job
        if let path = info.path, path.hasSuffix(".plist"), FileManager.default.isReadableFile(atPath: path),
           let parsed = parse(plistAt: URL(fileURLWithPath: path), location: location) {
            job = parsed
            job.label = label
            job.id = jobID(label: label, location: location)
        } else {
            var schedule = Schedule()
            schedule.atStartup = location.runsAsRoot
            let submittedByServiceManagement = info.managedBy == "com.apple.xpc.ServiceManagement" || (info.path?.hasPrefix("(submitted by smd") ?? false)
            schedule.atLogin = submittedByServiceManagement && !location.runsAsRoot
            schedule.runAtLoad = submittedByServiceManagement
            job = Job(
                id: jobID(label: label, location: location),
                source: .launchd,
                location: location,
                label: label,
                name: JobNaming.name(forLabel: label),
                schedule: schedule,
                arguments: info.arguments.isEmpty ? info.program.map { [$0] } ?? [] : info.arguments,
                stdoutPath: info.stdoutPath,
                stderrPath: info.stderrPath
            )
            // Submitted for the life of one program run; shown only when you ask for hidden tasks.
            if !submittedByServiceManagement, info.path?.hasPrefix("(submitted by") ?? false {
                job.looksSystemOwned = true
            }
        }
        if looksSystemOwned(label: label, program: job.arguments.first) { job.looksSystemOwned = true }
        job.totalRuns = info.runs
        return job
    }

    struct PrintInfo: Equatable {
        var path: String?
        var program: String?
        var arguments: [String] = []
        var stdoutPath: String?
        var stderrPath: String?
        var runs: Int?
        var lastExitCode: Int32?
        var pid: Int32?
        var managedBy: String?
    }

    /// Reads the top-level fields of `launchctl print <domain>/<label>`.
    /// The environment blocks are skipped on purpose: they often hold keys and tokens.
    static func parsePrint(_ output: String) -> PrintInfo {
        var info = PrintInfo()
        var inArguments = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if inArguments {
                if line.hasPrefix("\t}") { inArguments = false; continue }
                info.arguments.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            // Only fields one tab in belong to the job itself.
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "arguments = {" { inArguments = true; continue }
            guard let range = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[..<range.lowerBound])
            let value = String(trimmed[range.upperBound...])
            switch key {
            case "path": info.path = value
            case "program": info.program = value
            case "stdout path": info.stdoutPath = value
            case "stderr path": info.stderrPath = value
            case "runs": info.runs = Int(value)
            case "last exit code": info.lastExitCode = Int32(value)
            case "pid": info.pid = Int32(value)
            case "managed_by": info.managedBy = value
            default: break
            }
        }
        return info
    }

    // MARK: - launchctl

    struct Loaded: Equatable {
        var pid: Int32?
        var status: Int32
    }

    /// Parses `launchctl list`: PID, last exit status and label for every job in your session.
    static func loadedJobs() -> [String: Loaded] {
        parseList(Shell.launchctl("list").output)
    }

    static func parseList(_ output: String) -> [String: Loaded] {
        var result: [String: Loaded] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 3 else { continue }
            result[String(columns[2])] = Loaded(pid: Int32(columns[0]), status: Int32(columns[1]) ?? 0)
        }
        return result
    }

    /// Parses the `services = { … }` table of `launchctl print system`, which any user can read.
    /// Each row is PID (0 when not running), last exit status (or "-"), label.
    static func parseServices(_ output: String) -> [String: Loaded] {
        var result: [String: Loaded] = [:]
        var inServices = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !inServices {
                if line == "services = {" { inServices = true }
                continue
            }
            if line == "}" { break }
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3, let pid = Int32(columns[0]) else { continue }
            result[String(columns[2])] = Loaded(pid: pid == 0 ? nil : pid, status: Int32(columns[1]) ?? 0)
        }
        return result
    }

    static func disabledLabels(domain: String = Shell.guiDomain) -> Set<String> {
        parseDisabled(Shell.launchctl("print-disabled", domain).output)
    }

    static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return labels
    }

    /// Reads the run count from `launchctl print`, which `list` doesn't include.
    static func runCount(label: String, domain: String) -> Int? {
        parsePrint(Shell.launchctl("print", "\(domain)/\(label)").output).runs
    }

    private static func applyStatus(to job: inout Job, loaded: Loaded?, disabled: Bool) {
        guard let loaded, !disabled else {
            job.state = .paused
            return
        }
        job.pid = loaded.pid
        job.lastExitCode = loaded.status
        if job.totalRuns == nil, !job.looksSystemOwned, let domain = job.location.launchdDomain {
            job.totalRuns = runCount(label: job.label, domain: domain)
        }

        if loaded.pid != nil {
            job.state = .running
        } else if job.totalRuns == 0 {
            job.state = .waiting
        } else if loaded.status == 0 {
            job.state = .succeeded
        } else {
            job.state = .failed(exitCode: loaded.status)
        }
    }
}
