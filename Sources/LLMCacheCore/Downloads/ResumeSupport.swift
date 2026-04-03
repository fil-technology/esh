import Foundation

public enum ResumeSupport {
    public static func existingSize(at url: URL) -> Int64 {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else {
            return 0
        }

        return Int64(size)
    }
}
