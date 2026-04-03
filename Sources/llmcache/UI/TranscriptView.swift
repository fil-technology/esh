import Foundation

enum TranscriptView {
    static func render(lines: [String]) {
        if lines.isEmpty {
            print("Transcript is empty. Type a message, `/save`, or `/exit`.")
            return
        }

        for line in lines.suffix(20) {
            print(line)
        }
    }
}
