import Foundation

struct UpdateSessionStatus {
    var draft = false
    var unsaved = false
    var saveFailed = false
    var tasksRunning = false
    var journalFailed = false
}

@MainActor final class UpdateInstallGate {
    private struct Entry {
        weak var owner: AnyObject?
        let status: () -> UpdateSessionStatus
        let save: () -> Bool
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    func register(_ owner: AnyObject, status: @escaping () -> UpdateSessionStatus, save: @escaping () -> Bool) {
        entries[ObjectIdentifier(owner)] = Entry(owner: owner, status: status, save: save)
    }
    func unregister(_ owner: AnyObject) { entries.removeValue(forKey: ObjectIdentifier(owner)) }
    private var active: [Entry] {
        entries = entries.filter { $0.value.owner != nil }
        return Array(entries.values)
    }
    func blockers() -> [String] {
        Array(Set(active.flatMap { entry -> [String] in
            let value = entry.status()
            return [(value.draft, "draft"), (value.unsaved, "unsaved"), (value.saveFailed, "save"),
                    (value.tasksRunning, "tasks"), (value.journalFailed, "journal")].compactMap { $0.0 ? $0.1 : nil }
        })).sorted()
    }
    func prepare() -> [String] {
        let before = blockers()
        guard !before.contains("draft"), !before.contains("tasks") else { return before }
        var failed = false
        for entry in active {
            if !entry.save() { failed = true }
        }
        var after = blockers()
        if failed && !after.contains("save") { after.append("save") }
        return after.sorted()
    }
}
