import Foundation

public struct DownloadPlan: Sendable {
    public struct File: Hashable, Sendable {
        public var path: String
        public var sizeBytes: Int64?

        public init(path: String, sizeBytes: Int64?) {
            self.path = path
            self.sizeBytes = sizeBytes
        }
    }

    public var repoID: String
    public var revision: String
    public var files: [File]

    public init(repoID: String, revision: String, files: [File]) {
        self.repoID = repoID
        self.revision = revision
        self.files = files
    }
}

public struct DownloadCoordinator: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        plan: DownloadPlan,
        into destinationRoot: URL,
        reporter: ProgressReporting
    ) async throws -> [String] {
        var downloadedFiles: [String] = []
        let totalBytes = plan.files.compactMap(\.sizeBytes).reduce(0, +)
        var aggregateDownloaded: Int64 = 0
        let stopwatch = Stopwatch()

        for file in plan.files {
            let destinationURL = destinationRoot.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let downloadedBefore = ResumeSupport.existingSize(at: destinationURL)
            aggregateDownloaded += downloadedBefore

            reporter.emit(
                DownloadState(
                    phase: .downloading,
                    bytesDownloaded: aggregateDownloaded,
                    totalBytes: totalBytes > 0 ? totalBytes : nil,
                    bytesPerSecond: nil,
                    etaSeconds: nil,
                    currentFile: file.path,
                    message: downloadedBefore > 0 ? "Resuming" : "Starting"
                )
            )

            let request = try makeRequest(
                repoID: plan.repoID,
                revision: plan.revision,
                file: file.path,
                resumeFrom: downloadedBefore
            )
            let (bytes, response) = try await session.bytes(for: request)
            try validate(response: response, file: file.path, resumeFrom: downloadedBefore)

            let handle: FileHandle
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                handle = try FileHandle(forWritingTo: destinationURL)
            } else {
                FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: destinationURL)
            }
            defer { try? handle.close() }
            try handle.seekToEnd()

            var currentFileDownloaded = downloadedBefore
            var buffer = Data()
            buffer.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count < 64 * 1024 {
                    continue
                }

                try handle.write(contentsOf: buffer)
                let chunkCount = Int64(buffer.count)
                currentFileDownloaded += chunkCount
                aggregateDownloaded += chunkCount
                buffer.removeAll(keepingCapacity: true)

                let elapsed = max(stopwatch.elapsedMilliseconds() / 1_000, 0.001)
                let speed = Double(aggregateDownloaded) / elapsed
                let remaining = max(Double(totalBytes - aggregateDownloaded), 0)
                let eta = speed > 0 && totalBytes > 0 ? remaining / speed : nil

                reporter.emit(
                    DownloadState(
                        phase: .downloading,
                        bytesDownloaded: aggregateDownloaded,
                        totalBytes: totalBytes > 0 ? totalBytes : nil,
                        bytesPerSecond: speed,
                        etaSeconds: eta,
                        currentFile: file.path,
                        message: "Downloading"
                    )
                )
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                let chunkCount = Int64(buffer.count)
                currentFileDownloaded += chunkCount
                aggregateDownloaded += chunkCount
            }

            if let expected = file.sizeBytes, currentFileDownloaded < expected {
                throw StoreError.invalidManifest("Downloaded file \(file.path) is smaller than expected.")
            }

            downloadedFiles.append(file.path)
        }

        return downloadedFiles
    }

    private func makeRequest(
        repoID: String,
        revision: String,
        file: String,
        resumeFrom: Int64
    ) throws -> URLRequest {
        let encodedPath = file.split(separator: "/").map(String.init).joined(separator: "/")
        guard let url = URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(encodedPath)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    private func validate(response: URLResponse, file: String, resumeFrom: Int64) throws {
        guard let response = response as? HTTPURLResponse else { return }
        let acceptedCodes: Set<Int> = resumeFrom > 0 ? [200, 206] : [200]
        guard acceptedCodes.contains(response.statusCode) else {
            throw StoreError.invalidManifest("Download failed for \(file) with status \(response.statusCode).")
        }
    }
}
