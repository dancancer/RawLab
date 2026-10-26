import Foundation

@main struct MacUpdateTrustTests {
    static func main() throws {
        let certificate = String(repeating: "aB", count: 32)
        let selfSigned = try MacUpdateTrustMode.configured(certificate: certificate, team: nil)
        precondition(selfSigned == .certificate(certificate.lowercased()))
        let strict = try MacUpdateTrustMode.configured(certificate: nil, team: "A123456789")
        precondition(strict == .developerID("A123456789"))
        for pair: (String?, String?) in [(nil, nil), (certificate, "A123456789"), ("invalid", nil), (nil, "invalid")] {
            do { _ = try MacUpdateTrustMode.configured(certificate: pair.0, team: pair.1); fatalError("Invalid trust mode accepted") }
            catch let error as UpdateAdapterError { precondition(error.code == "configuration") }
        }
        print("PASS: Certificate and Developer ID modes require one complete, exclusive trust identity")
    }
}
