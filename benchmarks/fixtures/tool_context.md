## Failing test

```
Test failed: SummaryTests.titleSkipsSystemTurns
  Expected title "Fix the flaky cache test", got "You are a careful coding agent"
  at Tests/StoreTests/SummaryTests.swift:31
```

## File: Sources/Store/SummaryBuilder.swift

```swift
import Foundation

enum SummaryBuilder {
    /// The session title is the first few words of the conversation.
    static func title(for turns: [TurnRecord]) -> String {
        guard let first = turns.first else { return "Untitled" }
        let words = first.text.split(separator: " ").prefix(8)
        return words.joined(separator: " ")
    }

    static func turnCount(_ turns: [TurnRecord]) -> Int {
        turns.filter { $0.role != "system" }.count
    }
}
```

## File: Tests/StoreTests/SummaryTests.swift (excerpt)

```swift
func testTitleSkipsSystemTurns() {
    let turns = [TurnRecord(role: "system", text: "You are a careful coding agent"),
                 TurnRecord(role: "user", text: "Fix the flaky cache test")]
    XCTAssertEqual(SummaryBuilder.title(for: turns), "Fix the flaky cache test")
}
```
