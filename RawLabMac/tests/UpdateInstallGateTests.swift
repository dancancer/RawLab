import Foundation

@main struct UpdateInstallGateTests {
    @MainActor final class Session {
        var status = UpdateSessionStatus()
        var saveCalls = 0
        var saveSucceeds = true
        func save() -> Bool {
            saveCalls += 1
            if saveSucceeds { status.unsaved = false; status.saveFailed = false }
            return saveSucceeds
        }
    }
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }; print("PASS: \(message)")
    }
    @MainActor static func main() {
        let gate = UpdateInstallGate(), front = Session(), other = Session()
        gate.register(front, status: { front.status }, save: { front.save() })
        gate.register(other, status: { other.status }, save: { other.save() })
        other.status.draft = true
        check(gate.blockers().contains("draft"), "A background editing session blocks installation")
        check(gate.prepare().contains("draft") && front.saveCalls == 0 && other.saveCalls == 0, "Admission never applies or saves an active draft")
        other.status.draft = false; other.status.tasksRunning = true
        check(gate.prepare().contains("tasks") && other.saveCalls == 0, "Running tasks are not killed or treated as saved")
        other.status.tasksRunning = false; other.status.unsaved = true; other.saveSucceeds = false
        check(gate.blockers().contains("unsaved") && other.saveCalls == 0, "Reading software update status never saves edits")
        check(gate.prepare().contains("save") && other.saveCalls == 1, "Save failure blocks installation")
        other.saveSucceeds = true
        check(gate.prepare().isEmpty && other.saveCalls == 2, "Explicit admission saves committed edits and rechecks status")
        other.status.journalFailed = true
        check(gate.prepare().contains("journal"), "Finished worker with unsaved journal still blocks installation")
        gate.unregister(other)
        check(gate.blockers().isEmpty, "Closed sessions are removed from the gate")
    }
}
