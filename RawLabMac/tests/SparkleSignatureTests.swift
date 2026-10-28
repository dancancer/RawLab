import AppKit
import Sparkle

@main struct SparkleSignatureTests {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let driver = Driver()
                let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
                updater.automaticallyChecksForUpdates = false; updater.automaticallyDownloadsUpdates = false; updater.sendsSystemProfile = false
                try updater.start(); updater.checkForUpdates()
                for _ in 0..<600 {
                    if driver.error != nil { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard let error = driver.error else { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No framework rejection received"]) }
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                print("SDK_REJECTION outer=\(error.domain):\(error.code) underlying=\(underlying?.domain ?? "none"):\(underlying?.code ?? 0)")
                guard error.domain == SUSparkleErrorDomain, error.code == 1000,
                      underlying?.domain == SUSparkleErrorDomain, underlying?.code == 3002,
                      driver.unsafeStages == 0 else { throw error }
                print("PASS: Sparkle 2.10.0 rejects an unsigned appcast using its actual pinned-key verifier; no offer, download or installer stage")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor final class Driver: NSObject, SPUUserDriver {
        var error: NSError?
        var unsafeStages = 0
        func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
            reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
        }
        func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
        func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { unsafeStages += 1; reply(.skip) }
        func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
        func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
        func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { self.error = error as NSError; acknowledgement() }
        func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { self.error = error as NSError; acknowledgement() }
        func showDownloadInitiated(cancellation: @escaping () -> Void) { unsafeStages += 1; cancellation() }
        func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
        func showDownloadDidReceiveData(ofLength length: UInt64) {}
        func showDownloadDidStartExtractingUpdate() { unsafeStages += 1 }
        func showExtractionReceivedProgress(_ progress: Double) {}
        func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { unsafeStages += 1; reply(.skip) }
        func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) { unsafeStages += 1 }
        func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { unsafeStages += 1; acknowledgement() }
        func dismissUpdateInstallation() {}
    }
}
