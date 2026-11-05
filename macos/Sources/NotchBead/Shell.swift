import Foundation

struct ShellResult: Sendable {
    var status: Int32
    var output: String
}

enum Shell {
    /// Runs a program with fixed arguments (no shell in between) and waits for it.
    /// Call from a background task.
    static func run(_ executable: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, output: "")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

enum TimeText {
    /// "just now", "4 min ago", "2 h ago", "3 d ago"
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }
}
