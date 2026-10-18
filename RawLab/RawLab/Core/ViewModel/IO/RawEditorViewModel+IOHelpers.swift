import Foundation
import ImageIO
import UIKit

extension RawEditorViewModel {
    func copyToCache(_ sourceURL: URL, identity: PhotoIdentity?) throws -> URL {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = cacheRoot.appendingPathComponent("RawLab", isDirectory: true)

        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        let identityName = identity?.key.replacingOccurrences(of: "/", with: "_")
        let fileName = (identityName ?? UUID().uuidString) +
            (sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)")
        let destinationURL = cacheDir.appendingPathComponent(fileName)
        if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
            return destinationURL
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    func writeSmokeTestResult(_ message: String) {
        let fileManager = FileManager.default
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let cacheDir = cacheRoot.appendingPathComponent("RawLab", isDirectory: true)
        let resultURL = cacheDir.appendingPathComponent("smoke_test.txt")

        do {
            if !fileManager.fileExists(atPath: cacheDir.path) {
                try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            }
            try message.data(using: .utf8)?.write(to: resultURL)
        } catch {
            return
        }
    }
}
