// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import Foundation

/// Reads your crontab and the system one at /etc/crontab.
enum CronScanner {
    static let systemCrontab = "/etc/crontab"

    static func scan() -> [Job] {
        var jobs: [Job] = []
        let result = Shell.run("/usr/bin/crontab", ["-l"])
        if result.status == 0 { jobs += parse(result.output) }
        if let text = try? String(contentsOfFile: systemCrontab, encoding: .utf8) {
            jobs += parse(text, system: true)
        }
        return jobs
    }

    /// `system` reads the /etc/crontab format, which has a user column after the schedule.
    static func parse(_ crontab: String, system: Bool = false) -> [Job] {
        var jobs: [Job] = []
        var pendingComment: String?
        // cron gives each entry the variables set above it, on top of its own defaults.
        var assignments: [String: String] = [:]

        for rawLine in crontab.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                pendingComment = nil
                continue
            }
            if line.hasPrefix("#") {
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                // A commented-out entry is not a name.
                pendingComment = text.isEmpty || CronExpression(String(text.split(separator: " ").prefix(5).joined(separator: " "))) != nil ? nil : text
                continue
            }
            if let (name, value) = environmentAssignment(line) {
                assignments[name] = value
                continue
            }

            guard let entry = split(line, hasUser: system) else {
                pendingComment = nil
                continue
            }
            var schedule = Schedule()
            if entry.schedule.lowercased() == "@reboot" {
                schedule.atStartup = true
                schedule.runAtLoad = true
            } else if let cron = CronExpression(entry.schedule) {
                schedule.cron = cron
            } else {
                pendingComment = nil
                continue
            }

            let (command, _) = splitInput(entry.command)
            let shell = assignments["SHELL"] ?? "/bin/sh"
            let name = pendingComment.map(cleanComment) ?? JobNaming.name(forCommand: command)
            var job = Job(
                id: (system ? "cron-system:" : "cron:") + stableHash(line),
                source: .cron,
                location: system ? .systemCrontab : .userCrontab,
                label: line,
                name: name,
                schedule: schedule,
                arguments: [shell, "-c", command],
                cronLine: line,
                stdoutPath: logPath(in: command)
            )
            job.cronCommand = entry.command
            job.cronEnvironment = assignments
            job.runsAs = entry.user
            job.state = .waiting
            jobs.append(job)
            pendingComment = nil
        }
        return jobs
    }

    struct Entry: Equatable {
        var schedule: String
        var user: String?
        /// Everything after the schedule (and user), exactly as written.
        var command: String
    }

    /// Splits an entry into its schedule, user and command without touching the command's text,
    /// so quoted strings and runs of spaces reach the shell as cron would pass them.
    static func split(_ line: String, hasUser: Bool = false) -> Entry? {
        let scalars = Array(line)
        var index = 0
        func nextField() -> String? {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
            guard index < scalars.count else { return nil }
            let start = index
            while index < scalars.count, scalars[index] != " ", scalars[index] != "\t" { index += 1 }
            return String(scalars[start..<index])
        }

        guard let first = nextField() else { return nil }
        var fields = [first]
        if !first.hasPrefix("@") {
            for _ in 0..<4 {
                guard let field = nextField() else { return nil }
                fields.append(field)
            }
        }
        var user: String?
        if hasUser {
            guard let field = nextField() else { return nil }
            user = field
        }
        while index < scalars.count, scalars[index] == " " || scalars[index] == "\t" { index += 1 }
        let command = String(scalars[index...])
        guard !command.isEmpty else { return nil }
        return Entry(schedule: fields.joined(separator: " "), user: user, command: command)
    }

    /// cron treats an unescaped `%` as the end of the command; the text after it becomes the
    /// command's standard input, with each further `%` a newline. `\%` is a literal percent sign.
    static func splitInput(_ command: String) -> (command: String, input: String?) {
        var head = ""
        var input: String?
        var escaped = false
        for character in command {
            if escaped {
                if character != "%" { input == nil ? head.append("\\") : input!.append("\\") }
                input == nil ? head.append(character) : input!.append(character)
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "%" {
                if input == nil { input = "" } else { input!.append("\n") }
                continue
            }
            input == nil ? head.append(character) : input!.append(character)
        }
        if escaped { input == nil ? head.append("\\") : input!.append("\\") }
        return (head, input.map { $0 + "\n" })
    }

    /// The environment cron gives a job: its defaults, then the crontab's own variables.
    static func environment(for job: Job) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let user = NSUserName()
        var env = [
            "SHELL": "/bin/sh",
            "PATH": "/usr/bin:/bin",
            "HOME": home,
            "LOGNAME": user,
            "USER": user,
        ]
        for (name, value) in job.cronEnvironment where name != "LOGNAME" && name != "USER" {
            env[name] = value
        }
        return env
    }

    private static func environmentAssignment(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = String(value.dropFirst().dropLast())
        }
        return (name, value)
    }

    /// The file a command appends its output to, if any.
    static func logPath(in command: String) -> String? {
        let tokens = command.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            var target: String?
            if token == ">>" || token == ">" || token == "1>>" || token == "1>" {
                target = index + 1 < tokens.count ? tokens[index + 1] : nil
            } else if token.hasPrefix(">>") {
                target = String(token.dropFirst(2))
            } else if token.hasPrefix(">"), !token.hasPrefix(">&") {
                target = String(token.dropFirst())
            }
            if let target, !target.isEmpty, target != "/dev/null", !target.hasPrefix("&") {
                return (target as NSString).expandingTildeInPath
            }
        }
        return nil
    }

    private static func cleanComment(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// FNV-1a, so a job keeps its id (and history) across launches.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
