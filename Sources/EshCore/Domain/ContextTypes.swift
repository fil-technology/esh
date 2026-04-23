import Foundation

public struct SourceRange: Codable, Hashable, Sendable {
    public let lineStart: Int
    public let lineEnd: Int

    public init(lineStart: Int, lineEnd: Int) {
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}

public struct FileNode: Codable, Hashable, Sendable {
    public let path: String
    public let language: String?
    public let imports: [String]
    public let definedSymbols: [String]
    public let searchTokens: [String]
    public let lastModifiedAt: Date?
    public let contentHash: String

    public init(
        path: String,
        language: String?,
        imports: [String],
        definedSymbols: [String],
        searchTokens: [String] = [],
        lastModifiedAt: Date?,
        contentHash: String
    ) {
        self.path = path
        self.language = language
        self.imports = imports
        self.definedSymbols = definedSymbols
        self.searchTokens = searchTokens
        self.lastModifiedAt = lastModifiedAt
        self.contentHash = contentHash
    }

    enum CodingKeys: String, CodingKey {
        case path
        case language
        case imports
        case definedSymbols
        case searchTokens
        case lastModifiedAt
        case contentHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decode(String.self, forKey: .path)
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.imports = try container.decode([String].self, forKey: .imports)
        self.definedSymbols = try container.decode([String].self, forKey: .definedSymbols)
        self.searchTokens = try container.decodeIfPresent([String].self, forKey: .searchTokens) ?? []
        self.lastModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastModifiedAt)
        self.contentHash = try container.decode(String.self, forKey: .contentHash)
    }
}

public struct SymbolNode: Codable, Hashable, Sendable {
    public let name: String
    public let kind: String
    public let filePath: String
    public let lineStart: Int
    public let lineEnd: Int
    public let containerName: String?

    public init(
        name: String,
        kind: String,
        filePath: String,
        lineStart: Int,
        lineEnd: Int,
        containerName: String?
    ) {
        self.name = name
        self.kind = kind
        self.filePath = filePath
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.containerName = containerName
    }
}

public struct DependencyEdge: Codable, Hashable, Sendable {
    public let fromPath: String
    public let toPath: String
    public let kind: String

    public init(fromPath: String, toPath: String, kind: String) {
        self.fromPath = fromPath
        self.toPath = toPath
        self.kind = kind
    }
}

public struct RankedContextResult: Codable, Hashable, Sendable {
    public let filePath: String
    public let score: Double
    public let reasons: [String]
    public let suggestedRanges: [SourceRange]
    public let relatedSymbols: [String]

    public init(
        filePath: String,
        score: Double,
        reasons: [String],
        suggestedRanges: [SourceRange],
        relatedSymbols: [String]
    ) {
        self.filePath = filePath
        self.score = score
        self.reasons = reasons
        self.suggestedRanges = suggestedRanges
        self.relatedSymbols = relatedSymbols
    }
}

public struct ContextIndex: Codable, Hashable, Sendable {
    public let workspaceRootPath: String
    public let builtAt: Date
    public let files: [FileNode]
    public let symbols: [SymbolNode]
    public let edges: [DependencyEdge]

    public init(
        workspaceRootPath: String,
        builtAt: Date,
        files: [FileNode],
        symbols: [SymbolNode],
        edges: [DependencyEdge]
    ) {
        self.workspaceRootPath = workspaceRootPath
        self.builtAt = builtAt
        self.files = files
        self.symbols = symbols
        self.edges = edges
    }
}

public struct ContextStatus: Hashable, Sendable {
    public let workspaceRootPath: String
    public let builtAt: Date
    public let fileCount: Int
    public let symbolCount: Int
    public let edgeCount: Int

    public init(
        workspaceRootPath: String,
        builtAt: Date,
        fileCount: Int,
        symbolCount: Int,
        edgeCount: Int
    ) {
        self.workspaceRootPath = workspaceRootPath
        self.builtAt = builtAt
        self.fileCount = fileCount
        self.symbolCount = symbolCount
        self.edgeCount = edgeCount
    }
}

public struct SymbolReadResult: Hashable, Sendable {
    public let symbol: SymbolNode
    public let fileURL: URL
    public let range: SourceRange
    public let lines: [String]

    public init(symbol: SymbolNode, fileURL: URL, range: SourceRange, lines: [String]) {
        self.symbol = symbol
        self.fileURL = fileURL
        self.range = range
        self.lines = lines
    }
}

public struct FileReadResult: Hashable, Sendable {
    public let fileURL: URL
    public let range: SourceRange
    public let lines: [String]

    public init(fileURL: URL, range: SourceRange, lines: [String]) {
        self.fileURL = fileURL
        self.range = range
        self.lines = lines
    }
}
