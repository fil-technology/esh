import Foundation
import Testing
@testable import EshCore

@Suite
struct DownloadCoordinatorTests {
    @Test
    func existingSizeUsesPartialFileLength() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("partial.bin")
        try Data(repeating: 1, count: 128).write(to: fileURL)

        #expect(ResumeSupport.existingSize(at: fileURL) == 128)
    }
}
