import Foundation
import CryptoKit

extension MacUpdateTrust {
    func validatePackage(at archive: URL, release: UpdateDescriptor, signature: String) throws {
        let bytes = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard bytes.count == release.size,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == release.sha256,
              let encodedKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: encodedKey),
              let signatureData = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: bytes) else {
            throw UpdateAdapterError(code: "signature", detail: "Update archive does not match its signed metadata")
        }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rawlab-package-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let extract = Process(); extract.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        extract.arguments = ["-x", "-k", archive.path, directory.path]
        extract.standardOutput = FileHandle.nullDevice; extract.standardError = FileHandle.nullDevice
        try extract.run(); extract.waitUntilExit()
        guard extract.terminationStatus == 0 else { throw UpdateAdapterError(code: "package", detail: "Cannot extract update archive") }
        try Task.checkCancellation()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { $0.lastPathComponent != "__MACOSX" }
        guard contents.count == 1, let app = contents.first, app.pathExtension == "app",
              try app.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let candidate = Bundle(url: app), candidate.bundleIdentifier == bundle.bundleIdentifier,
              candidate.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              candidate.object(forInfoDictionaryKey: "CFBundleVersion") as? String == release.build,
              candidate.object(forInfoDictionaryKey: "RawLabUpdateArchitecture") as? String == architecture else {
            throw UpdateAdapterError(code: "identity", detail: "Update bundle does not match the selected release")
        }
        try validateCode(in: candidate)
    }
}
