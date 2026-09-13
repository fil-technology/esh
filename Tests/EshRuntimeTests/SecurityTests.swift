import Foundation
import Testing
import EshCore
@testable import EshRuntime

// M10 #11 — security/privacy guards on the model-management path.
@Suite
struct SecurityTests {
    private func mgr() -> LocalModelManager {
        LocalModelManager(root: PersistenceRoot(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent("esh-sec-\(UUID())")))
    }
    private func desc(id: String, url: String) -> LocalModelDescriptor {
        LocalModelDescriptor(id: id, displayName: "x", sourceURL: URL(string: url)!, repository: "t/t",
                             license: "apache-2.0", expectedBytes: 10, sha256: String(repeating: "0", count: 64),
                             quantization: "Q4_K_M", parameterCountB: 0.1, recommendedHardwareClass: "test")
    }

    @Test func pathTraversalIdsAreRejected() {
        for bad in ["../evil", "a/b", "..", ".", "foo/../bar", "with space", "", String(repeating: "x", count: 200)] {
            #expect(LocalModelDescriptor.isValidID(bad) == false, "\(bad) should be invalid")
        }
        for good in ["qwen2.5-0.5b-instruct-q4km", "model_1", "A.B-c"] {
            #expect(LocalModelDescriptor.isValidID(good), "\(good) should be valid")
        }
    }

    @Test func installRejectsTraversalId() async {
        await #expect(throws: LocalModelError.self) {
            _ = try await mgr().install(desc(id: "../../etc/passwd", url: "https://huggingface.co/x.gguf"))
        }
    }

    @Test func installRejectsInsecureSource() async {
        // remote plaintext HTTP and file:// are refused; HTTPS and loopback are allowed.
        #expect(LocalModelDescriptor.isSecureSource(URL(string: "http://evil.example/x.gguf")!) == false)
        #expect(LocalModelDescriptor.isSecureSource(URL(string: "file:///etc/passwd")!) == false)
        #expect(LocalModelDescriptor.isSecureSource(URL(string: "https://huggingface.co/x.gguf")!))
        #expect(LocalModelDescriptor.isSecureSource(URL(string: "http://127.0.0.1:8080/x.gguf")!))
        await #expect(throws: LocalModelError.self) {
            _ = try await mgr().install(desc(id: "ok", url: "http://evil.example/x.gguf"))
        }
    }

    @Test func removeRejectsTraversalId() async {
        await #expect(throws: LocalModelError.self) { try await mgr().remove("../../etc") }
    }

    @Test func curatedCatalogIsAllHttpsAndSafeIds() {
        for m in LocalModelCatalog.models {
            #expect(LocalModelDescriptor.isValidID(m.id))
            #expect(LocalModelDescriptor.isSecureSource(m.sourceURL))
            #expect(m.sourceURL.scheme == "https")
        }
    }
}
