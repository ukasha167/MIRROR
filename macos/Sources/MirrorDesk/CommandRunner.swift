import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case failed(command: String, exitCode: Int32, stderr: String)
    case notFound(tool: String, searched: [String])

    public var description: String {
        switch self {
        case .failed(let command, let code, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) exited with \(code)\(detail.isEmpty ? "" : ": \(detail)")"
        case .notFound(let tool, let searched):
            return "\(tool) not found (looked in \(searched.joined(separator: ", ")))"
        }
    }
}

/// Runs a command to completion. Tests swap in a scripted fake so nothing needs a phone.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
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
                    cont.resume(throwing: error)
                    return
                }
                // Read before waiting, so a full pipe buffer cannot block the child.
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}

/// Finds command-line tools. A menu bar app launched from Finder gets a minimal PATH
/// without Homebrew, so look in the usual install locations too.
public enum ToolLocator {
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        if name == "adb" {
            let home = environment["HOME"] ?? NSHomeDirectory()
            if let sdk = environment["ANDROID_HOME"] { dirs.append("\(sdk)/platform-tools") }
            dirs.append("\(home)/Library/Android/sdk/platform-tools")
        }
        for dir in dirs {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw CommandError.notFound(tool: name, searched: dirs)
    }
}
