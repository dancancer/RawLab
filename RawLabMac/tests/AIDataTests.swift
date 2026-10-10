import AppKit
import ImageIO
import UniformTypeIdentifiers

private enum TestFailure: Error { case failed(String) }
private func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try value() else { throw TestFailure.failed(name) }
    print("PASS: \(name)")
}
private func rejects(_ name: String, _ body: () throws -> Void) throws {
    do { try body() } catch { print("PASS: \(name)"); return }
    throw TestFailure.failed(name)
}

private final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var status = 200
    static var body = Data()
    static var recorded: URLRequest?
    static var calls = 0
    static func reply(_ value: Data, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        self.body = value; self.status = status; recorded = nil; calls = 0
    }
    static func lastRequest() -> URLRequest? { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.recorded = captured; Self.calls += 1
        let status = Self.status, data = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct AIDataTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let recipe = AIColorRecipe.identity(name: "Test look", summary: "Synthetic test")
        let data = try JSONEncoder().encode(recipe)
        let decoded = try AIColorRecipe.decode(data)
        try check(try AIToneRegions.standard.validated().parameters == [0.2, 0.6, 0.4, 0.8],
                  "Tone regions remain separate from the forty style parameters")
        let regions = AIToneRegions(shadowStart: 0.1, shadowEnd: 0.45, highlightStart: 0.55, highlightEnd: 0.95)
        try check(try JSONDecoder().decode(AIToneRegions.self, from: JSONEncoder().encode(regions)) == regions,
                  "Manual regions round trip independently")
        for bad in [AIToneRegions(shadowStart: .nan, shadowEnd: 0.6, highlightStart: 0.4, highlightEnd: 0.8),
                    AIToneRegions(shadowStart: 0.5, shadowEnd: 0.6, highlightStart: 0.4, highlightEnd: 0.8),
                    AIToneRegions(shadowStart: 0.2, shadowEnd: 0.9, highlightStart: 0.4, highlightEnd: 0.8),
                    AIToneRegions(shadowStart: 0.2, shadowEnd: 0.21, highlightStart: 0.4, highlightEnd: 0.8)] {
            try rejects("Invalid tone regions are rejected") { _ = try bad.validated() }
        }
        try check(decoded.parameters.count == 40 && decoded.parameters[9] == 1 && decoded.parameters[8] == 1,
                  "Recipe contract maps to forty native parameters")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["unknown"] = 1
        try rejects("Unknown recipe fields are rejected") { _ = try AIColorRecipe.decode(JSONSerialization.data(withJSONObject: object)) }
        object.removeValue(forKey: "unknown"); object["version"] = 2
        try rejects("Unknown recipe versions are rejected") { _ = try AIColorRecipe.decode(JSONSerialization.data(withJSONObject: object)) }
        object["version"] = 1; object["chroma"] = 2.1
        try rejects("Out of range values are rejected rather than clamped") { _ = try AIColorRecipe.decode(JSONSerialization.data(withJSONObject: object)) }
        object["chroma"] = 1; object["tone"] = [0,0.2,0.1,0.4,0.5,0.6,0.7,0.8,1]
        try rejects("Nonmonotonic curves are rejected") { _ = try AIColorRecipe.decode(JSONSerialization.data(withJSONObject: object)) }
        try rejects("Natural-language wrappers are not parsed as recipes") { _ = try AIColorRecipe.decode(Data("```json\n{}\n```".utf8)) }

        let configuration = AIConfiguration(baseURL: "https://API.DEEPSEEK.COM:443/v1/", model: "deepseek-flash")
        try check(try configuration.normalizedURL().absoluteString == "https://api.deepseek.com/v1",
                  "Service addresses are normalized for Keychain separation")
        try check(try configuration.endpoint("chat/completions").absoluteString == "https://api.deepseek.com/v1/chat/completions",
                  "Configured base paths are preserved")
        for address in ["http://api.deepseek.com", "https://user:secret@api.deepseek.com", "https://api.deepseek.com?key=x", "https://api.deepseek.com/#fragment"] {
            try rejects("Unsafe API address is rejected") { _ = try AIConfiguration(baseURL: address, model: "test").normalizedURL() }
        }

        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let prepared = try AIImage.prepare(context.makeImage()!, name: "private-name.jpg")
        try check(prepared.image.width == 1600 && prepared.image.height == 800 && prepared.jpeg.count <= 2*1024*1024,
                  "Upload image has bounded dimensions and bytes")
        try check(prepared.image.colorSpace?.name == CGColorSpace.sRGB, "Upload pixels are converted to sRGB")
        let source = CGImageSourceCreateWithData(prepared.jpeg as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        let technicalExif = properties[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        let allowedExif: Set<String> = [kCGImagePropertyExifColorSpace as String, kCGImagePropertyExifPixelXDimension as String,
                                       kCGImagePropertyExifPixelYDimension as String]
        try check(properties[kCGImagePropertyGPSDictionary] == nil && Set(technicalExif.keys).isSubset(of: allowedExif),
                  "Reencoded JPEG retains only technical color and dimension tags")
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ai-image-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let inputWriter = CGImageDestinationCreateWithURL(inputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let metadata: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Private photographer"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 22.0, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 113.0, kCGImagePropertyGPSLongitudeRef: "E"]]
        CGImageDestinationAddImage(inputWriter, context.makeImage()!, metadata as CFDictionary)
        try check(CGImageDestinationFinalize(inputWriter), "Write metadata-bearing reference fixture")
        let loaded = try AIImage.load(inputURL)
        let cleanSource = CGImageSourceCreateWithData(loaded.jpeg as CFData, nil)!
        let clean = CGImageSourceCopyPropertiesAtIndex(cleanSource, 0, nil)! as NSDictionary
        let cleanExif = clean[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        try check(loaded.image.width == 800 && loaded.image.height == 1600, "Reference orientation is applied before upload")
        try check(clean[kCGImagePropertyGPSDictionary] == nil && clean[kCGImagePropertyTIFFDictionary] == nil &&
                  Set(cleanExif.keys).isSubset(of: allowedExif), "GPS, photographer and capture date do not survive upload preparation")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FixtureProtocol.self]
        let service = AIService(sessionConfiguration: sessionConfiguration)
        let response: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": String(data: data, encoding: .utf8)!]]]]
        FixtureProtocol.reply(try JSONSerialization.data(withJSONObject: response))
        let result = try await service.generate(configuration: configuration, key: "test-only-key",
            images: [prepared, prepared], instruction: "cooler shadows", previous: nil)
        try check(result.name == recipe.name, "API decodes the complete validated recipe")
        let request = FixtureProtocol.lastRequest()!
        let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key" && request.httpMethod == "POST",
                  "API sends explicit authentication to the configured service")
        try check((payload["response_format"] as? [String: String])?["type"] == "json_object", "API requests JSON output")
        let payloadText = String(data: request.httpBody!, encoding: .utf8)!
        try check(!payloadText.contains("private-name.jpg") && !payloadText.contains("test-only-key"),
                  "Image filenames and credentials are absent from request body")
        _ = try await service.generate(configuration: configuration, key: "test-only-key",
            images: [prepared, prepared, prepared], instruction: "refine", previous: recipe,
            previousStrength: 0.8, previousRegions: regions)
        let refinedText = String(data: FixtureProtocol.lastRequest()!.httpBody!, encoding: .utf8)!
        try check(refinedText.contains("shadowEnd") && refinedText.contains("0.45") &&
                  refinedText.contains("80%") && refinedText.contains("default boundaries 0.2, 0.6, 0.4, 0.8"),
                  "Refinement includes actual manual boundaries and states the next recipe reset")
        FixtureProtocol.reply(Data("{\"error\":\"secret remote contents\"}".utf8), status: 401)
        do {
            _ = try await service.generate(configuration: configuration, key: "test-only-key", images: [prepared, prepared], instruction: "", previous: nil)
            throw TestFailure.failed("401 should fail")
        } catch let error as AIError {
            try check(error.localizedDescription.contains("API Key") && !error.localizedDescription.contains("secret"),
                      "Authentication error is classified without leaking remote body")
        }
        FixtureProtocol.reply(Data("{}".utf8), status: 429)
        do {
            _ = try await service.generate(configuration: configuration, key: "key", images: [prepared, prepared], instruction: "", previous: nil)
            throw TestFailure.failed("429 should fail")
        } catch is AIError { try check(FixtureProtocol.calls == 1, "Rate limiting does not silently retry billed requests") }
        FixtureProtocol.reply(try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": String(data: data, encoding: .utf8)!]]]]))
        do {
            _ = try await service.generate(configuration: configuration, key: "key", images: [prepared, prepared], instruction: "", previous: nil)
            throw TestFailure.failed("Truncation should fail")
        } catch is AIError { print("PASS: Truncated results are rejected even if partial JSON looks valid") }
        FixtureProtocol.reply(Data("{\"data\":[{\"id\":\"deepseek-flash\",\"input_modalities\":[\"text\",\"image\"]}]}".utf8))
        let models = try await service.models(configuration: configuration, key: "key")
        try check(models.contains("deepseek-flash") && FixtureProtocol.lastRequest()?.httpMethod == "GET" &&
                  FixtureProtocol.lastRequest()?.httpBody == nil, "Connection test sends no private images")
        FixtureProtocol.reply(Data(repeating: 32, count: 256*1024+1))
        do {
            _ = try await service.models(configuration: configuration, key: "key")
            throw TestFailure.failed("Oversized response should fail")
        } catch let error as AIError { try check(error.localizedDescription.contains("大小限制"), "Unknown-length streaming responses are bounded") }
        FixtureProtocol.reply(Data("{}".utf8))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.generate(configuration: configuration, key: "key", images: [prepared, prepared], instruction: "", previous: nil)
        }
        do { _ = try await cancelled.value; throw TestFailure.failed("Cancelled task should fail") }
        catch is CancellationError { try check(FixtureProtocol.calls == 0, "Already cancelled work sends no request") }
    }
}
