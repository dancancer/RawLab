import Foundation

@main struct UpdateStateTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }; print("PASS: \(message)")
    }
    static func main() throws {
        let release = UpdateDescriptor(version: "0.9.1", build: "19", platform: "macos", architecture: "arm64",
            channel: "stable", assetURL: "https://example.invalid/update.zip", size: 123, sha256: nil, notes: "Release")
        let defaults = UpdatePreferences()
        check(defaults.automaticCheck && !defaults.automaticInstall, "Only update checks are enabled by default")
        var state = UpdateTaskState()
        let checkToken = state.beginCheck(); check(state.found(release, token: checkToken), "New release enters available")
        check(!state.verified(token: checkToken), "Available metadata is not a verified package")
        let download = state.beginDownload()!
        check(state.received(0.7, token: download) && state.received(0.2, token: download) && state.progress == 0.7, "Progress cannot move backwards")
        check(!state.installing(token: download), "Downloading cannot bypass verification and admission")
        check(state.preparing(token: download), "Download completion starts verification")
        check(state.fail("signature", detail: "Rejected", token: download), "Signature failure retains verification stage")
        check(!state.verified(token: download) && state.phase == .failed, "Late verification cannot overwrite a failure")
        var restored = try JSONDecoder().decode(UpdateTaskState.self, from: JSONEncoder().encode(state))
        restored.restoreAfterLaunch(version: "0.8.2", build: "14", trusted: true)
        check(restored.phase == .failed && restored.failure?.stage == .verifying, "Reopening preserves failure and failed stage")
        let next = state.beginCheck(); _ = state.found(release, token: next)
        let retry = state.beginDownload()!
        check(!state.preparing(token: download), "Retry invalidates old callbacks")
        _ = state.preparing(token: retry); _ = state.verified(token: retry)
        check(!state.admit(blockedBy: []) && !state.installing(token: retry), "Verified package needs an explicit installation choice")
        _ = state.choose(.afterTasks)
        check(!state.admit(blockedBy: ["draft", "export"]) && state.phase == .waitingForTasks, "Drafts and tasks block installation")
        check(!state.installing(token: retry), "Waiting cannot directly install")
        check(state.admit(blockedBy: []) && state.installing(token: retry), "Re-admission allows installation after tasks finish")
        check(state.awaitingRestart(token: retry), "Installer dispatch is pending restart, not complete")
        restored = try JSONDecoder().decode(UpdateTaskState.self, from: JSONEncoder().encode(state))
        restored.restoreAfterLaunch(version: release.version, build: release.build, trusted: false)
        check(restored.phase == .failed, "Matching version without trusted startup is not success")
        state.restoreAfterLaunch(version: release.version, build: release.build, trusted: true)
        check(state.phase == .complete, "Trusted matching first startup completes the update")
        let again = state.beginCheck(); _ = state.found(release, token: again)
        let auto = state.beginDownload()!; _ = state.preparing(token: auto); _ = state.verified(token: auto)
        _ = state.choose(.automaticOnQuit); state.disableAutomaticInstallation()
        check(state.phase == .available && state.choice == .none && !state.installing(token: auto), "Disabling automatic install revokes the queued attempt")
        let cancelled = state.beginDownload()!; state.cancel()
        check(!state.received(1, token: cancelled) && !state.preparing(token: cancelled), "Cancelled callbacks cannot revive an update")
    }
}
