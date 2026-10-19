import Foundation

extension RawEditorViewModel {
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
