import Foundation
import Sparkle

@main struct SparkleUpdateAdapterTests {
    @MainActor static func main() async {
        let trust = MacUpdateTrust(feed: URL(string: "https://example.invalid/appcast.xml")!,
            mode: .certificate(String(repeating: "0", count: 64)), architecture: "arm64", bundle: .main)
        let adapter = SparkleUpdateAdapter(trust: trust)
        var rejected = false
        adapter.showReady { rejected = $0 == .skip }
        precondition(rejected && !adapter.hasPreparedInstaller,
            "An SDK ready callback without package identity verification must not permit installation")
        var precheckRejected = false
        do { try await adapter.prepareInstall() }
        catch is UpdateAdapterError { precheckRejected = true }
        catch {}
        precondition(precheckRejected,
            "Pre-install check must reject an unverified host or missing ready callback before recording installing")
        print("PASS: SDK readiness alone cannot authorize an unverified package")
    }
}
