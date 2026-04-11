import Foundation

public struct ContextEvaluationCase: Codable, Hashable, Sendable {
    public let query: String
    public let expectedFiles: [String]

    public init(query: String, expectedFiles: [String]) {
        self.query = query
        self.expectedFiles = expectedFiles
    }
}

public struct ContextEvaluationQueryResult: Codable, Hashable, Sendable {
    public let query: String
    public let expectedFiles: [String]
    public let returnedFiles: [String]
    public let firstRelevantRank: Int?

    public init(query: String, expectedFiles: [String], returnedFiles: [String], firstRelevantRank: Int?) {
        self.query = query
        self.expectedFiles = expectedFiles
        self.returnedFiles = returnedFiles
        self.firstRelevantRank = firstRelevantRank
    }
}

public struct ContextEvaluationReport: Codable, Hashable, Sendable {
    public let caseCount: Int
    public let top1Hits: Int
    public let top3Hits: Int
    public let meanReciprocalRank: Double
    public let queries: [ContextEvaluationQueryResult]

    public init(
        caseCount: Int,
        top1Hits: Int,
        top3Hits: Int,
        meanReciprocalRank: Double,
        queries: [ContextEvaluationQueryResult]
    ) {
        self.caseCount = caseCount
        self.top1Hits = top1Hits
        self.top3Hits = top3Hits
        self.meanReciprocalRank = meanReciprocalRank
        self.queries = queries
    }
}

public struct ContextEvaluationHarness: Sendable {
    private let queryEngine: ContextQueryEngine

    public init(queryEngine: ContextQueryEngine = .init()) {
        self.queryEngine = queryEngine
    }

    public func evaluate(
        cases: [ContextEvaluationCase],
        index: ContextIndex,
        limit: Int = 5
    ) -> ContextEvaluationReport {
        let queries = cases.map { item -> ContextEvaluationQueryResult in
            let results = queryEngine.query(item.query, in: index, limit: limit)
            let returnedFiles = results.map(\.filePath)
            let firstRelevantRank = returnedFiles.firstIndex { file in
                item.expectedFiles.contains(file)
            }.map { $0 + 1 }
            return ContextEvaluationQueryResult(
                query: item.query,
                expectedFiles: item.expectedFiles,
                returnedFiles: returnedFiles,
                firstRelevantRank: firstRelevantRank
            )
        }

        let top1Hits = queries.filter { $0.firstRelevantRank == 1 }.count
        let top3Hits = queries.filter { ($0.firstRelevantRank ?? .max) <= 3 }.count
        let reciprocalRanks = queries.compactMap { query -> Double? in
            guard let rank = query.firstRelevantRank else { return nil }
            return 1.0 / Double(rank)
        }
        let mrr = cases.isEmpty ? 0 : reciprocalRanks.reduce(0, +) / Double(cases.count)

        return ContextEvaluationReport(
            caseCount: cases.count,
            top1Hits: top1Hits,
            top3Hits: top3Hits,
            meanReciprocalRank: mrr,
            queries: queries
        )
    }
}
