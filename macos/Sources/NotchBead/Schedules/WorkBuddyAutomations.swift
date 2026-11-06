// Adapted from onit (MIT, Copyright (c) 2026 Neethan Wu).
import Foundation

/// WorkBuddy's scheduled prompts, read from its database (read-only), shown with your other scheduled tasks.
/// Only names, status and schedules are read, never the prompts.
enum WorkBuddyAutomations {
    struct Automation: Decodable {
        var id: String
        var name: String
        var status: String?
        var rrule: String?
        var next_run_at: Double?
        var last_run_at: Double?
    }

    static func scan() -> [Job] {
        guard let data = WorkBuddyAttention.query("""
            SELECT id, name, status, rrule, next_run_at, last_run_at
            FROM automations WHERE deleted_at IS NULL OR deleted_at = -1
            """), !data.isEmpty,
              let rows = try? JSONDecoder().decode([Automation].self, from: data)
        else { return [] }
        return rows.map(job)
    }

    static func job(_ row: Automation) -> Job {
        var schedule = row.rrule.map(CodexAutomations.parseRRule) ?? Schedule()
        if schedule.calendar.isEmpty, schedule.interval == nil, let next = row.next_run_at {
            schedule.once = Date(timeIntervalSince1970: next / 1000)
        }
        var job = Job(
            id: "workbuddy:\(row.id)",
            source: .automation,
            location: .workBuddyAutomation,
            label: row.id,
            name: row.name,
            schedule: schedule,
            arguments: ["WorkBuddy"]
        )
        job.state = row.status?.uppercased() == "ACTIVE" ? .waiting : .paused
        job.lastRun = row.last_run_at.map { Date(timeIntervalSince1970: $0 / 1000) }
        return job
    }
}
