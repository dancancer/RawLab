import Foundation
import Darwin

enum AIFileExporter {
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(_ url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
                  let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else {
                throw AIError.message("导出目标不是普通文件。")
            }
            self.device = device.uint64Value; self.inode = inode.uint64Value
            self.size = size.uint64Value; self.modified = modified
        }
        func aliases(_ other: Self) -> Bool { device == other.device && inode == other.inode }
    }

    static func write(source: URL, destination: URL, protecting originals: [URL], overwrite: Bool) throws {
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        let destination = destination.standardizedFileURL
        let before: FileIdentity?
        if manager.fileExists(atPath: destination.path) {
            guard overwrite else { throw AIError.message("目标文件已存在，请先确认覆盖或选择其他名称。") }
            before = try FileIdentity(destination)
        } else { before = nil }
        for original in originals + [source] {
            if original.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath() ||
                (before != nil && (try? FileIdentity(original)).map { before!.aliases($0) } == true) {
                throw AIError.message("不能覆盖原始照片、参考图或外观源文件，请选择其他位置。")
            }
        }
        guard destination.pathExtension.lowercased() == "cube" else { throw AIError.message("导出文件必须使用 .cube 扩展名。") }
        let temporary = try AITemporaryDirectory(parent: destination.deletingLastPathComponent())
        let staged = temporary.url.appendingPathComponent("share.cube")
        let status = source.path.withCString { input in
            staged.path.withCString { output in sony2fuji_export_color_look(input, output) }
        }
        guard status == SONY2FUJI_STATUS_OK else { throw AIError.message("此外观无法导出为 sRGB CUBE，源文件可能已损坏或不兼容。") }
        if let before {
            guard let current = try? FileIdentity(destination), current == before else {
                throw AIError.message("目标文件在导出期间发生变化，未覆盖。请重新选择位置。")
            }
            let result = staged.path.withCString { input in destination.path.withCString { output in Darwin.rename(input, output) } }
            guard result == 0 else { throw AIError.message("无法写入 CUBE，请检查目标位置和磁盘空间。") }
        } else {
            do { try manager.linkItem(at: staged, to: destination) }
            catch { throw AIError.message("无法写入 CUBE，目标可能已存在或不可写。") }
        }
    }
}
