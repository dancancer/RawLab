import Foundation
import CryptoKit

// Sparkle 2.10 appcast signing block: Sparkle/SPUExtractSignedFeed.m.
func run() throws {
    let args = CommandLine.arguments
    guard args.count == 4 || args.count == 5,
          let keyData = Data(base64Encoded: args[1]) else { throw NSError(domain: "usage", code: 1) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
    let content: Data, signature: Data
    if args[3] == "feed" {
        let prefix = Data("<!-- sparkle-signatures:\n".utf8)
        guard let range = bytes.range(of: prefix, options: .backwards),
              let block = String(data: bytes[range.upperBound...], encoding: .utf8), block.hasSuffix("-->\n") else {
            throw NSError(domain: "missing feed signature", code: 1)
        }
        let fields = Dictionary(block.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { _, _ in "" })
        content = Data(bytes[..<range.lowerBound])
        guard fields["length"].flatMap(Int.init) == content.count,
              let parsed = fields["edSignature"].flatMap({ Data(base64Encoded: $0) }) else {
            throw NSError(domain: "invalid feed signature", code: 1)
        }
        signature = parsed
    } else {
        guard args[3] == "archive", args.count == 5, let parsed = Data(base64Encoded: args[4]) else {
            throw NSError(domain: "invalid archive signature", code: 1)
        }
        content = bytes; signature = parsed
    }
    guard key.isValidSignature(signature, for: content) else { throw NSError(domain: "signature mismatch", code: 1) }
    print("PASS: Sparkle signature verified using public key")
}
do { try run() } catch { fputs("Sparkle verification failed: \(error)\n", stderr); exit(1) }
