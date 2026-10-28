import Foundation
import CryptoKit

@main struct MacUpdatePackageTests {
    static func main() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        if CommandLine.arguments[1] == "public-key" {
            print(key.publicKey.rawRepresentation.base64EncodedString()); return
        }
        let host = Bundle(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
        let archive = URL(fileURLWithPath: CommandLine.arguments[2]), expected = CommandLine.arguments[3]
        let trust = try MacUpdateTrust.configured(bundle: host)
        let bytes = try Data(contentsOf: archive)
        let release = UpdateDescriptor(version: "1.0", build: "1", platform: "macos", architecture: trust.architecture,
            channel: "stable", assetURL: "https://example.invalid/update.zip", size: UInt64(bytes.count),
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), notes: "")
        let signature = try key.signature(for: bytes).base64EncodedString()
        do {
            try trust.validatePackage(at: archive, release: release,
                signature: expected == "signature" ? Data(repeating: 0, count: 64).base64EncodedString() : signature)
            precondition(expected == "accept", "Untrusted update package accepted: \(expected)")
            print("PASS: valid signed update package accepted")
        } catch let error as UpdateAdapterError {
            precondition(expected != "accept" && error.code == expected, "Unexpected package rejection: \(error)")
            print("PASS: update package rejected at \(expected) before installation")
        }
    }
}
