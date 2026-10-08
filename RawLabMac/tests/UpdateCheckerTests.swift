import Foundation

@main
struct UpdateCheckerTests {
    @MainActor static func main() async throws {
        let suite = "RawLab.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data("""
        {"tag_name":"v0.5.0","draft":false,"prerelease":false,"body":"Notes",
         "assets":[{"name":"RawLab-Mac-arm64.zip"},{"name":"RawLab-Mac-x86_64.zip"}]}
        """.utf8)
        var calls = 0
        var fail = false
        let checker = UpdateChecker(defaults: defaults, currentVersion: "0.4.0", fetch: {
            calls += 1
            if fail { throw URLError(.notConnectedToInternet) }
            return data
        })
        checker.automatic = false
        await checker.check(manual: false)
        precondition(calls == 0 && !checker.checking)
        await checker.check(manual: true)
        precondition(calls == 1 && checker.available?.version == "0.5.0" && !checker.checking)
        checker.automatic = true
        await checker.check(manual: false)
        precondition(calls == 1)
        let restored = UpdateChecker(defaults: defaults, currentVersion: "0.4.0", fetch: { data })
        precondition(restored.available?.version == "0.5.0" && restored.automatic)
        fail = true
        await checker.check(manual: true)
        precondition(calls == 2 && !checker.checking && checker.available?.version == "0.5.0")
        precondition(checker.status.contains("失败"))
        let upgraded = UpdateChecker(defaults: defaults, currentVersion: "0.5.0", fetch: { data })
        precondition(upgraded.available == nil)

        var continuation: CheckedContinuation<Data, Never>?
        let delayed = UpdateChecker(defaults: defaults, currentVersion: "0.4.0", fetch: {
            await withCheckedContinuation { continuation = $0 }
        })
        let task = Task { await delayed.check(manual: true) }
        while continuation == nil { await Task.yield() }
        precondition(delayed.checking)
        await delayed.check(manual: true)
        continuation!.resume(returning: data)
        await task.value
        precondition(!delayed.checking && delayed.available?.version == "0.5.0")
        print("PASS: opt-out, manual retry, cache, interval, failure and concurrent-check state")
    }
}
