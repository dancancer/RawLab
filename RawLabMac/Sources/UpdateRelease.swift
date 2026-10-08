import Foundation

struct UpdateRelease {
    static let repository = URL(string: "https://github.com/dancancer/RawLab")!
    static let author = URL(string: "https://www.xiaohongshu.com/user/profile/6474b1560000000010037c8e")!
    static let endpoint = URL(string: "https://api.github.com/repos/dancancer/RawLab/releases/latest")!
    let version: String
    let notes: String
    let url: URL

    private struct Payload: Decodable {
        struct Asset: Decodable { let name: String }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let body: String?
        let assets: [Asset]
    }

    static func parse(_ data: Data, current: String, assetSuffix: String) throws -> UpdateRelease? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }
        let latest = try numbers(payload.tag_name)
        let installed = try numbers(current)
        guard installed.lexicographicallyPrecedes(latest),
              payload.assets.contains(where: { $0.name.hasPrefix("RawLab-Mac-") && $0.name.hasSuffix(assetSuffix) })
        else { return nil }
        return UpdateRelease(version: latest.map(String.init).joined(separator: "."),
                             notes: payload.body ?? "", url: repository.appendingPathComponent("releases/tag/\(payload.tag_name)"))
    }

    private static func numbers(_ text: String) throws -> [Int] {
        guard text.range(of: "^v?[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else {
            throw CocoaError(.coderInvalidValue)
        }
        let plain = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = plain.split(separator: ".")
        var values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { throw CocoaError(.coderInvalidValue) }
        if values.count == 2 { values.append(0) }
        return values
    }

    static func shouldCheck(manual: Bool, enabled: Bool, last: Double, now: Double) -> Bool {
        manual || (enabled && (last == 0 || now < last || now - last >= 86400))
    }
}
