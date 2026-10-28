import Foundation

@main struct BatchSelectionSessionTests {
    static func main() {
        var session = BatchSelectionSession<String>()
        session.append(["source", "same-name-A", "same-name-B", "source", "third"])
        precondition(session.ordered == ["source", "same-name-A", "same-name-B", "third"])
        session.select("same-name-B", false)
        precondition(session.targets(excluding: "source") == ["same-name-A", "third"])
        precondition(session.beginEditing("third"))
        precondition(session.current == "third" && session.returnPosition == "third")
        session.returnToCollection()
        precondition(session.current == nil && session.returnPosition == "third")
        precondition(session.selected == ["source", "same-name-A", "third"])
        let synchronization = UUID()
        session.recordSynchronization(synchronization, changed: true)
        session.recordSynchronization(UUID(), changed: false)
        precondition(session.lastSynchronization == synchronization)
        // 预检跳过属于操作，不能更改集合勾选；再次操作从原选择重新取目标。
        let skipped: Set<String> = ["same-name-A"]
        precondition(session.targets(excluding: "source").filter { !skipped.contains($0) } == ["third"])
        precondition(session.targets(excluding: "source") == ["same-name-A", "third"])
        session.remove("third")
        precondition(session.returnPosition == nil && !session.selected.contains("third"))
        precondition(!session.beginEditing("missing"))
        print("PASS: ordered identities, source exclusion, selection, edit return and synchronization history")
    }
}
