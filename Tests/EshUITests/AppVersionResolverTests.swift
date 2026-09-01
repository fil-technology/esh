import Foundation
import Testing
@testable import esh

@Suite
struct AppVersionResolverTests {
    // Regression guard: `esh version` reported "unknown" for the 2.0.0-rc.1 VERSION because the
    // semver check rejected the pre-release suffix. RC/pre-release versions must be recognized.
    @Test
    func acceptsReleaseAndPreReleaseVersions() {
        #expect(AppVersionResolver.isSemver("2.0.0"))
        #expect(AppVersionResolver.isSemver("0.9.7"))
        #expect(AppVersionResolver.isSemver("2.0.0-rc.1"))
        #expect(AppVersionResolver.isSemver("2.0.0-rc.2"))
        #expect(AppVersionResolver.isSemver("10.20.30-beta.1"))
    }

    @Test
    func rejectsMalformedVersions() {
        #expect(AppVersionResolver.isSemver("unknown") == false)
        #expect(AppVersionResolver.isSemver("2.0") == false)
        #expect(AppVersionResolver.isSemver("2.0.0.0") == false)
        #expect(AppVersionResolver.isSemver("v2.0.0") == false)
        #expect(AppVersionResolver.isSemver("") == false)
    }
}
