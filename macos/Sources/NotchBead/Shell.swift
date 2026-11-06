import Foundation

struct ShellResult: Sendable {
    var status: Int32
    var output: String
    var error: String
}

enum Shell {
    /// Runs a program and waits for it. Call from a background task.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, output: "", error: error.localizedDescription)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            error: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Starts a crontab command the way cron does, without waiting for it: the command text exactly
    /// as written, cron's environment and shell, the home folder as working directory, and any
    /// `%` input on standard input. Nothing else is added or changed.
    static func runLikeCron(_ crontabCommand: String, environment: [String: String]) {
        let (command, input) = CronScanner.splitInput(crontabCommand)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment["SHELL"] ?? "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
    }

    @discardableResult
    static func launchctl(_ arguments: String...) -> ShellResult {
        run("/bin/launchctl", arguments)
    }

    static var guiDomain: String { "gui/\(getuid())" }
}
