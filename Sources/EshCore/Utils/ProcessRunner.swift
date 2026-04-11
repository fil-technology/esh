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
        stdin: Data? = nil
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

        process.waitUntilExit()
        group.wait()
        return ProcessOutput(
            stdout: stdoutData.load(),
            stderr: stderrData.load(),
            exitCode: process.terminationStatus
        )
    }
}
