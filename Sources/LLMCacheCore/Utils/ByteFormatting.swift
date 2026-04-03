import Foundation

public enum ByteFormatting {
    public static func string(for bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
