import Foundation

public struct ProcessOutput: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum ProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        stdin: Data? = nil,
        currentDirectoryURL: URL? = nil
    ) throws -> ProcessOutput {
        try run(executableURL: executableURL, arguments: arguments, environment: environment,
                stdin: stdin, currentDirectoryURL: currentDirectoryURL, cancellable: false)
    }

    /// Cooperatively-cancellable variant: while the subprocess runs, polls `Task.isCancelled` and, if the
    /// surrounding Task is cancelled, terminates the process (SIGTERM, then SIGKILL after a short grace) and
    /// throws `CancellationError`. Used by long-running capability providers (e.g. image.upscale) so a
    /// user cancel actually stops the work and reclaims memory — no orphan subprocess.
    public static func runCancellable(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        stdin: Data? = nil,
        currentDirectoryURL: URL? = nil
    ) throws -> ProcessOutput {
        try run(executableURL: executableURL, arguments: arguments, environment: environment,
                stdin: stdin, currentDirectoryURL: currentDirectoryURL, cancellable: true)
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        stdin: Data?,
        currentDirectoryURL: URL?,
        cancellable: Bool
    ) throws -> ProcessOutput {
        final class DataSink: @unchecked Sendable {
            private let lock = NSLock()
            private var value = Data()

            func store(_ newValue: Data) {
                lock.lock()
                value = newValue
                lock.unlock()
            }

            func load() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let group = DispatchGroup()
        let stdoutData = DataSink()
        let stderrData = DataSink()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData.store(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData.store(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        if let stdin {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdin)
            try stdinPipe.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        if cancellable {
            while process.isRunning {
                if Task.isCancelled {
                    process.terminate()   // SIGTERM
                    let deadline = Date().addingTimeInterval(2.0)
                    while process.isRunning && Date() < deadline { usleep(50_000) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    group.wait()          // let reader threads drain to EOF (no leaked FDs)
                    throw CancellationError()
                }
                usleep(50_000)            // 50 ms poll
            }
        } else {
            process.waitUntilExit()
        }
        group.wait()
        return ProcessOutput(
            stdout: stdoutData.load(),
            stderr: stderrData.load(),
            exitCode: process.terminationStatus
        )
    }
}
