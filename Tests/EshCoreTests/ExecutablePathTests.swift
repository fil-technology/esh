import Foundation
import Testing
@testable import EshCore

@Suite
struct ExecutablePathTests {

    @Test
    func resolvesAnAbsoluteExistingPathIndependentOfCWD() {
        let url = ExecutablePath.resolvedURL()
        // Must be absolute and point at a real file — never a CWD-relative guess from argv[0].
        #expect(url.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(ExecutablePath.resolvedPath == url.path)
    }

    @Test
    func doesNotDependOnArgv0BeingAValidPath() {
        // The whole point of the resolver: even under PATH/shim invocation where argv[0] is a bare
        // name, we still get the true executable image path from the OS. We can't rewrite argv[0]
        // in-process, but we can assert the resolver never returns a CWD-relative fabrication.
        let resolved = ExecutablePath.resolvedURL().path
        #expect(resolved != CommandLine.arguments.first || resolved.hasPrefix("/"))
    }
}
