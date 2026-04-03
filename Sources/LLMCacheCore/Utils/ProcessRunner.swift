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
        var stdoutData = Data()
        var stderrData = Data()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
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
            stdout: stdoutData,
            stderr: stderrData,
            exitCode: process.terminationStatus
        )
    }
}
