import Foundation

/// Result of a finished subprocess.
public struct ShellResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
    public var stdoutTrimmed: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var stderrTrimmed: String { stderr.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A non-zero exit from a checked command.
public struct ShellError: Error, CustomStringConvertible, LocalizedError {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public var description: String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return "`\(command)` failed (exit \(exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
    }

    public var errorDescription: String? { description }
}

/// Thin async/await wrapper over `Foundation.Process`. Zero-dependency, the
/// standard for shelling out. Resolves executables via PATH (`/usr/bin/env`),
/// drains stdout/stderr concurrently to avoid pipe-buffer deadlocks, and offers a
/// detached-launch path for long-lived processes like `tart run` that must
/// outlive the graft invocation.
public enum Shell {
    /// Run a command to completion and capture its output. Does not throw on a
    /// non-zero exit — inspect `ShellResult.exitCode`. Throws only if the process
    /// can't be launched.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        // Drain both pipes concurrently — reading only after exit risks a deadlock
        // if output exceeds the ~64KB pipe buffer.
        async let outData = drain(outPipe.fileHandleForReading)
        async let errData = drain(errPipe.fileHandleForReading)
        let (out, err) = await (outData, errData)

        process.waitUntilExit()

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    /// Run a command and return trimmed stdout, throwing `ShellError` on non-zero exit.
    @discardableResult
    public static func runChecked(
        _ executable: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil
    ) async throws -> String {
        let result = try await run(executable, arguments, environment: environment)
        guard result.succeeded else {
            throw ShellError(
                command: ([executable] + arguments).joined(separator: " "),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        }
        return result.stdoutTrimmed
    }

    /// Run a command with stdout/stderr inherited by this process (so output
    /// streams live, e.g. a runner's job logs into the launchd log) and an optional
    /// string fed to stdin. Blocks until the command exits; returns its exit code.
    public static func runStreaming(
        _ executable: String,
        _ arguments: [String] = [],
        stdin: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        let inputPipe = Pipe()
        if stdin != nil { process.standardInput = inputPipe }

        return try await withCheckedThrowingContinuation { continuation in
            // Set before run() so we never miss a fast-exiting process.
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                if let stdin {
                    let handle = inputPipe.fileHandleForWriting
                    handle.write(Data(stdin.utf8))
                    try? handle.close()
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Launch a command fully detached (`nohup … &`) so it survives this process
    /// exiting. Used for `tart run`, where the VM stays alive only as long as the
    /// run process does — and we want `graft vm create` to return while it keeps
    /// running. Returns as soon as the shell backgrounds the job.
    public static func launchDetached(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup \(command) >/dev/null 2>&1 &"]
        process.environment = ProcessInfo.processInfo.environment
        try process.run()
        process.waitUntilExit()
    }

    /// Drain a pipe to EOF off the cooperative pool using POSIX `read`, keeping the
    /// non-`Sendable` `FileHandle` out of the concurrent closure.
    private static func drain(_ handle: FileHandle) async -> Data {
        let fd = handle.fileDescriptor
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var data = Data()
                let capacity = 65_536
                var buffer = [UInt8](repeating: 0, count: capacity)
                while true {
                    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, capacity) }
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])
                }
                continuation.resume(returning: data)
            }
        }
    }
}
