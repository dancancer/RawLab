import Foundation

@main
struct UpdateReleaseTests {
    static func main() throws {
        func check(_ value: Bool) { precondition(value) }
        func payload(_ tag: String, draft: Bool = false, preview: Bool = false,
                     asset: String = "RawLab-Mac-0.5.0-macOS15-arm64.zip") -> Data {
            try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft,
                "prerelease": preview, "body": "Release notes", "assets": [["name": asset]]])
        }
        func update(_ tag: String, current: String = "0.4.0") throws -> UpdateRelease? {
            try UpdateRelease.parse(payload(tag), current: current, assetSuffix: "arm64.zip")
        }
        check(try update("v0.10.0")?.version == "0.10.0")
        check(try update("v0.4") == nil)
        check(try update("v0.3.9") == nil)
        check(try update("v0.4.1")?.url.absoluteString == "https://github.com/dancancer/RawLab/releases/tag/v0.4.1")
        for tag in ["v0.5.0-beta", "v0.5.0/evil", "bad", "0.-1.0"] {
            do { _ = try update(tag); preconditionFailure("Invalid tag accepted: \(tag)") } catch { }
        }
        check(try UpdateRelease.parse(payload("v0.5.0", draft: true), current: "0.4.0", assetSuffix: "arm64.zip") == nil)
        check(try UpdateRelease.parse(payload("v0.5.0", preview: true), current: "0.4.0", assetSuffix: "arm64.zip") == nil)
        check(try UpdateRelease.parse(payload("v0.5.0", asset: "RawLab-Android.apk"), current: "0.4.0", assetSuffix: "arm64.zip") == nil)
        precondition(UpdateRelease.shouldCheck(manual: true, enabled: false, last: 100, now: 101))
        precondition(!UpdateRelease.shouldCheck(manual: false, enabled: false, last: 0, now: 100000))
        precondition(!UpdateRelease.shouldCheck(manual: false, enabled: true, last: 100, now: 101))
        precondition(UpdateRelease.shouldCheck(manual: false, enabled: true, last: 100, now: 86500))
        precondition(UpdateRelease.shouldCheck(manual: false, enabled: true, last: 200, now: 100))
        print("PASS: release validation, numeric versions, platform assets, manual and daily checks")
    }
}
