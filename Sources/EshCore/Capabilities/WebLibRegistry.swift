import Foundation
import CryptoKit

// esh 2.1 UCMR — Managed Project Runtime, Phase 2: curated web-library dependency policy.
//
// Generated Tier-B (browser-module) projects may only use libraries from this CURATED, PINNED, integrity-
// verified allowlist. Libraries are VENDORED OFFLINE by esh (download once, verify, pin — the same discipline
// as models) under `<assets>/caches/web-libs/<id>/<version>/`; a generation request never triggers a live
// download. The provider copies the vendored files INTO the artifact bundle (`vendor/<id>/…`) and injects an
// ES-module import map, so the project stays same-origin + self-contained (works under the opaque-origin
// sandbox and CSP `connect-src 'none'`). An unknown/unpinned library is REJECTED, never auto-installed.

/// One curated, pinned browser library.
public struct WebLib: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        public let filename: String          // e.g. "three.module.min.js"
        public let sha256: String            // pinned integrity hash (lowercase hex)
        public let importSpecifier: String?  // the bare ES specifier this file satisfies (e.g. "three"); nil = side file
        public init(filename: String, sha256: String, importSpecifier: String?) {
            self.filename = filename; self.sha256 = sha256; self.importSpecifier = importSpecifier
        }
    }
    public let id: String        // "three"
    public let version: String   // "0.160.0"
    public let license: String   // "MIT"
    public let files: [File]
    public let sourceURL: String // provenance: where esh vendored it from (maintainer step, not runtime)
    /// The library's conventional browser global (e.g. Three.js → "THREE"). When set, esh's bootstrap exposes
    /// the imported module under this global so natural `THREE.*` code works without a correct ESM import.
    public let globalName: String?
    public init(id: String, version: String, license: String, files: [File], sourceURL: String, globalName: String? = nil) {
        self.id = id; self.version = version; self.license = license; self.files = files
        self.sourceURL = sourceURL; self.globalName = globalName
    }
    /// In-bundle subdirectory the files are copied into.
    public var bundleDir: String { "vendor/\(id)" }
}

/// The curated allowlist. Adding a library is a deliberate, maintainer-reviewed act (pin + hash + vendor).
public enum WebLibRegistry {
    public static let all: [WebLib] = [
        WebLib(id: "three", version: "0.160.0", license: "MIT",
               files: [.init(filename: "three.module.min.js",
                             sha256: "3e690ac7d180b0aadf0891bea39eec643e29e2d3e75c99b18689518665f69ba6",
                             importSpecifier: "three")],
               sourceURL: "https://cdnjs.cloudflare.com/ajax/libs/three.js/0.160.0/three.module.min.js",
               globalName: "THREE")
    ]
    public static func entry(for id: String) -> WebLib? {
        all.first { $0.id.lowercased() == id.lowercased() }
    }
    public static var approvedNames: [String] { all.map { $0.id } }
}

/// The outcome of resolving a project's requested dependencies against the registry.
public struct DependencyResolution: Sendable, Equatable {
    /// Pinned dependencies for the ProjectArtifact v2 manifest.
    public var resolved: [ResolvedDependency]
    /// ES-module import map: bare specifier → in-bundle RELATIVE path (e.g. "three" → "./vendor/three/three.module.min.js").
    public var importMap: [String: String]
    /// Files to copy INTO the artifact bundle: in-bundle relative path → absolute path in the offline cache.
    public var bundleFiles: [String: String]
    /// Requested names that are not on the curated allowlist (or not vendored) — rejected, never installed.
    public var rejected: [String]

    public var hasRejections: Bool { !rejected.isEmpty }
}

/// Resolves requested library names against the curated registry + the offline vendor cache.
public struct DependencyResolver: Sendable {
    /// `<assets>/caches/web-libs`.
    public let cacheRoot: URL
    /// The curated allowlist to resolve against (injectable for testing; defaults to the real registry).
    public let registry: [WebLib]
    public init(cacheRoot: URL, registry: [WebLib] = WebLibRegistry.all) {
        self.cacheRoot = cacheRoot
        self.registry = registry
    }

    public func cacheDir(for lib: WebLib) -> URL {
        cacheRoot.appendingPathComponent("\(lib.id)/\(lib.version)", isDirectory: true)
    }

    /// Which approved libraries the JS sources actually USE — detected from a bare ES import of the library id
    /// OR from a reference to its conventional global (e.g. `THREE.`). This lets esh resolve + vendor + expose
    /// a library even when the model writes global-style code without a correct ESM import.
    public func usedLibIDs(in jsSources: [String]) -> [String] {
        var ids: [String] = []
        for lib in registry {
            let importedByName = jsSources.contains { src in
                BrowserModuleComposer.imports(inJS: src).contains {
                    $0.kind == .bare && $0.specifier.lowercased() == lib.id.lowercased()
                }
            }
            let usedAsGlobal: Bool = {
                guard let g = lib.globalName else { return false }
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: g))\\b"
                return jsSources.contains { $0.range(of: pattern, options: .regularExpression) != nil }
            }()
            if importedByName || usedAsGlobal { ids.append(lib.id) }
        }
        return ids
    }

    /// Resolve the requested bare specifiers. Unknown names → `rejected`. Known names that are not present
    /// (or fail integrity) in the offline cache are ALSO rejected (esh never fetches at request time).
    public func resolve(_ requested: [String]) -> DependencyResolution {
        var resolved: [ResolvedDependency] = []
        var importMap: [String: String] = [:]
        var bundleFiles: [String: String] = [:]
        var rejected: [String] = []
        var seen = Set<String>()
        for raw in requested {
            let name = raw.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || !seen.insert(name.lowercased()).inserted { continue }
            guard let lib = registry.first(where: { $0.id.lowercased() == name.lowercased() }) else { rejected.append(name); continue }
            let dir = cacheDir(for: lib)
            var allPresent = true
            for f in lib.files where !WebLibVendor.verify(file: f, at: dir.appendingPathComponent(f.filename)) {
                allPresent = false
            }
            guard allPresent else { rejected.append(name); continue }
            for f in lib.files {
                let bundlePath = "\(lib.bundleDir)/\(f.filename)"
                bundleFiles[bundlePath] = dir.appendingPathComponent(f.filename).path
                if let spec = f.importSpecifier { importMap[spec] = "./\(bundlePath)" }
            }
            resolved.append(ResolvedDependency(name: lib.id, version: lib.version,
                                               integritySHA256: lib.files.first?.sha256,
                                               source: .vendored, scope: .browser))
        }
        return DependencyResolution(resolved: resolved, importMap: importMap, bundleFiles: bundleFiles, rejected: rejected)
    }
}

/// Reads/verifies vendored library bytes from the offline cache. No network at request time.
public enum WebLibVendor {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// True iff the file exists at `url` and its content matches the pinned sha256.
    public static func verify(file: WebLib.File, at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return sha256Hex(data) == file.sha256.lowercased()
    }
    /// Read the bytes to copy into an artifact bundle, re-verifying integrity. Throws if missing/tampered.
    public static func bytes(at absolutePath: String, expectedSHA256: String?) throws -> Data {
        let url = URL(fileURLWithPath: absolutePath)
        guard let data = try? Data(contentsOf: url) else {
            throw CapabilityError.failed("vendored library file missing: \(absolutePath)")
        }
        if let expected = expectedSHA256, sha256Hex(data) != expected.lowercased() {
            throw CapabilityError.failed("vendored library integrity mismatch: \(url.lastPathComponent)")
        }
        return data
    }
}
