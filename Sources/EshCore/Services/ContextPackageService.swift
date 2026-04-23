import Foundation

public struct ContextPackageService: Sendable {
    private let store: ContextPackageStore
    private let planner: ContextPlanningService

    public init(
        store: ContextPackageStore = FileContextPackageStore(),
        planner: ContextPlanningService = .init()
    ) {
        self.store = store
        self.planner = planner
    }

    public func resolveBrief(
        task: String,
        index: ContextIndex,
        workspaceRootURL: URL,
        runTrace: RunTrace? = nil,
        limit: Int = 5,
        snippetCount: Int = 3,
        modelID: String? = nil,
        intent: SessionIntent? = nil,
        cacheMode: CacheMode? = nil
    ) throws -> ContextPackageResolution {
        let fingerprint = taskFingerprint(
            task: task,
            modelID: modelID,
            intent: intent,
            cacheMode: cacheMode,
            limit: limit,
            snippetCount: snippetCount
        )

        if let reusable = try reusablePackage(
            taskFingerprint: fingerprint,
            workspaceRootURL: workspaceRootURL,
            index: index,
            modelID: modelID,
            intent: intent,
            cacheMode: cacheMode
        ) {
            let refreshedBrief = planner.refreshBrief(reusable.brief, runTrace: runTrace)
            return ContextPackageResolution(package: reusable, brief: refreshedBrief, reused: true)
        }

        let brief = try planner.makeBrief(
            task: task,
            index: index,
            workspaceRootURL: workspaceRootURL,
            runTrace: runTrace,
            limit: limit,
            snippetCount: snippetCount
        )

        let package = try buildPackage(
            brief: brief,
            task: task,
            taskFingerprint: fingerprint,
            index: index,
            workspaceRootURL: workspaceRootURL,
            modelID: modelID,
            intent: intent,
            cacheMode: cacheMode
        )
        try store.savePackage(package, workspaceRootURL: workspaceRootURL)
        return ContextPackageResolution(package: package, brief: brief, reused: false)
    }

    private func reusablePackage(
        taskFingerprint: String,
        workspaceRootURL: URL,
        index: ContextIndex,
        modelID: String?,
        intent: SessionIntent?,
        cacheMode: CacheMode?
    ) throws -> ContextPackage? {
        let packages = try store.listPackages(workspaceRootURL: workspaceRootURL)
        let hashesByPath = Dictionary(uniqueKeysWithValues: index.files.map { ($0.path, $0.contentHash) })

        return packages.first { package in
            guard package.manifest.taskFingerprint == taskFingerprint,
                  package.manifest.modelID == modelID,
                  package.manifest.intent == intent,
                  package.manifest.cacheMode == cacheMode else {
                return false
            }
            return package.manifest.files.allSatisfy { file in
                hashesByPath[file.path] == file.contentHash
            }
        }
    }

    private func buildPackage(
        brief: ContextPlanningBrief,
        task: String,
        taskFingerprint: String,
        index: ContextIndex,
        workspaceRootURL: URL,
        modelID: String?,
        intent: SessionIntent?,
        cacheMode: CacheMode?
    ) throws -> ContextPackage {
        let hashesByPath = Dictionary(uniqueKeysWithValues: index.files.map { ($0.path, $0.contentHash) })
        let filePaths = Set(brief.rankedResults.map(\.filePath) + brief.snippets.map(\.filePath))
        let files = filePaths.sorted().compactMap { path -> ContextPackageFile? in
            guard let hash = hashesByPath[path] else { return nil }
            return ContextPackageFile(path: path, contentHash: hash)
        }
        let manifest = ContextPackageManifest(
            workspaceRootPath: workspaceRootURL.path,
            task: task,
            taskFingerprint: taskFingerprint,
            modelID: modelID,
            intent: intent,
            cacheMode: cacheMode,
            files: files
        )
        return ContextPackage(
            manifest: manifest,
            packagePath: "",
            sizeBytes: 0,
            brief: brief
        )
    }

    private func taskFingerprint(
        task: String,
        modelID: String?,
        intent: SessionIntent?,
        cacheMode: CacheMode?,
        limit: Int,
        snippetCount: Int
    ) -> String {
        let normalizedTask = task
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return Fingerprint.sha256([
            normalizedTask,
            modelID ?? "",
            intent?.rawValue ?? "",
            cacheMode?.rawValue ?? "",
            String(limit),
            String(snippetCount)
        ])
    }
}
