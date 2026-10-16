import CryptoKit
import Foundation
import UIKit

@main
struct BundledLookArtworkTests {
    static func main() throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let folder = resources.appendingPathComponent("BundledLooks")
        let data = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let looks = try JSONDecoder().decode([BundledLook].self, from: data)
        let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        precondition(looks.count == 29)
        for (look, row) in zip(looks, rows) {
            let cube = try Data(contentsOf: folder.appendingPathComponent(look.fileName))
            let digest = SHA256.hash(data: cube).map { String(format: "%02x", $0) }.joined()
            precondition(digest == row["sha256"] as? String, "Stale bundled LUT: \(look.id)")
            let candidates = [resources.appendingPathComponent(look.artworkName + ".png"),
                              folder.appendingPathComponent("Artwork/" + look.artworkName + ".png")]
            guard let image = candidates.compactMap({ UIImage(contentsOfFile: $0.path) }).first,
                  let bitmap = image.cgImage else { fatalError("Missing native artwork: \(look.id)") }
            precondition(bitmap.width == bitmap.height && bitmap.width >= 256)
            let font = UIFont.preferredFont(forTextStyle: .caption1)
            let metrics = UIFontMetrics(forTextStyle: .caption1)
            let width = metrics.scaledValue(for: 138) - 12
            let height = metrics.scaledValue(for: 34)
            let bounds = (look.name as NSString).boundingRect(with: CGSize(width: width, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            precondition(bounds.height <= height + 1,
                         "Bundled label exceeds reserved height: \(look.name), \(bounds.height) > \(height), width \(width), font \(font.pointSize)")
            print("PASS: iOS native LUT hash, artwork and label: \(look.name)")
        }
    }
}
