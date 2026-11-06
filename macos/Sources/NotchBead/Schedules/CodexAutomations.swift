// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import Foundation

/// Scheduled prompts set up in the Codex app, one folder each under ~/.codex/automations.
enum CodexAutomations {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/automations")
    }

    static func scan() -> [Job] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { entry in
            let file = entry.appendingPathComponent("automation.toml")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return job(fromTOML: text, file: file)
        }
    }

    static func job(fromTOML text: String, file: URL) -> Job? {
        let fields = parseTopLevel(text)
        guard let id = fields["id"] else { return nil }
        var schedule = fields["rrule"].map(parseRRule) ?? Schedule()
        schedule.runAtLoad = false
        var job = Job(
            id: "codex:\(id)",
            source: .automation,
            location: .codexAutomation,
            label: id,
            name: fields["name"] ?? id,
            schedule: schedule,
            arguments: ["Codex"],
            plistURL: file
        )
        // Only the name and schedule are read: the prompt can be long and personal.
        job.state = fields["status"]?.uppercased() == "ACTIVE" ? .waiting : .paused
        return job
    }

    /// Reads `key = "value"` and `key = value` lines before the first table.
    static func parseTopLevel(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { break }
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\n", with: "\n")
            }
            fields[key] = value
        }
        return fields
    }

    private static let weekdays = ["SU": 0, "MO": 1, "TU": 2, "WE": 3, "TH": 4, "FR": 5, "SA": 6]

    /// Turns the iCalendar rules Codex writes (HOURLY, DAILY, WEEKLY with BYDAY/BYHOUR/BYMINUTE)
    /// into launchd-style times, so they read and count down like everything else.
    static func parseRRule(_ rule: String) -> Schedule {
        var parts: [String: String] = [:]
        for part in rule.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { parts[pair[0].uppercased()] = pair[1] }
        }
        func numbers(_ key: String) -> [Int?] {
            guard let text = parts[key] else { return [nil] }
            let values = text.split(separator: ",").compactMap { Int($0) }
            return values.isEmpty ? [nil] : values
        }
        let interval = parts["INTERVAL"].flatMap(Int.init) ?? 1
        var schedule = Schedule()
        switch parts["FREQ"]?.uppercased() {
        case "MINUTELY":
            schedule.interval = 60 * interval
        case "HOURLY" where interval > 1 || parts["BYMINUTE"] == nil:
            schedule.interval = 3600 * interval
        case "HOURLY":
            schedule.calendar = numbers("BYMINUTE").map { CalendarSpec(minute: $0 ?? 0) }
        case "DAILY", "WEEKLY":
            if interval > 1, parts["FREQ"] == "DAILY" { schedule.interval = 86_400 * interval; break }
            let days = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { weekdays[String($0.suffix(2)).uppercased()] }
            let everyDay = days.isEmpty ? parts["FREQ"] == "DAILY" : Set(days).count == 7
            for hour in numbers("BYHOUR") {
                for minute in numbers("BYMINUTE") {
                    if everyDay {
                        schedule.calendar.append(CalendarSpec(minute: minute ?? 0, hour: hour ?? 0))
                    } else {
                        for day in days { schedule.calendar.append(CalendarSpec(minute: minute ?? 0, hour: hour ?? 0, weekday: day)) }
                    }
                }
            }
        default:
            break
        }
        return schedule
    }
}
