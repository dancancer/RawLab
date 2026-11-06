import Foundation

@main struct WorkspaceBrowserTests {
    @MainActor static func main() async throws {
        let model = MacWorkspaceBrowserState()
        let root = PhotoFolder(URL(fileURLWithPath: "/roll"))
        let nested = PhotoFolder(URL(fileURLWithPath: "/roll/shoot"))
        let photos = (0..<2_468).map { nested.url.appendingPathComponent("photo-\($0).png") }
        let other = root.url.appendingPathComponent("other.png")
        root.expanded = true
        model.browse([root, nested], load: false)
        let location = model.location!
        model.remember(photos[1_842], in: location, grid: false)
        model.remember(photos[5], in: location, grid: true)
        model.collapseBranch()
        precondition(!root.expanded && model.folder === nested)
        precondition(model.anchor(in: location, grid: false) == photos[1_842])
        model.goUp(load: false)
        precondition(model.folder === root)
        model.browse([root, nested], load: false)
        precondition(model.anchor(in: location, grid: true) == photos[5])
        precondition(model.anchor(in: location, grid: false) == photos[1_842])

        precondition(!model.activate(photos[9], in: photos, extending: false, mouseClickCount: nil))
        precondition(!model.activate(photos[12], in: photos, extending: true, mouseClickCount: nil))
        precondition(model.selection == Array(photos[9...12]))
        model.goUp(load: false)
        precondition(!model.activate(other, in: [other], extending: true, mouseClickCount: nil))
        precondition(model.selection == Array(photos[9...12]) + [other])
        model.removeSelection([photos[10], other])
        precondition(model.selection == [photos[9], photos[11], photos[12]])

        let marked = model.selection
        precondition(!model.activate(photos[30], in: photos, extending: false, mouseClickCount: 1))
        precondition(model.includes(photos[30]))
        precondition(model.activate(photos[30], in: photos, extending: false, mouseClickCount: 2))
        precondition(model.selection == marked && !model.includes(photos[30]))
        precondition(!model.activate(photos[9], in: photos, extending: false, mouseClickCount: 1))
        precondition(!model.includes(photos[9]))
        precondition(model.activate(photos[9], in: photos, extending: false, mouseClickCount: 2))
        precondition(model.selection == marked && model.includes(photos[9]))

        var remaining = photos
        remaining.remove(at: 1_842)
        precondition(model.restoreAnchor(in: location, grid: false, photos: remaining) == photos[1_843])
        precondition(model.anchor(in: location, grid: false) == photos[1_843])
        try await verifyDirectoryRetry()
        print("PASS detached folder navigation, large-directory anchors, retry, Shift selection, double-click, partial handoff")
    }

    @MainActor private static func verifyDirectoryRetry() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("rawlab-workspace-\(UUID())", isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let shoot = root.appendingPathComponent("Shoot", isDirectory: true)
        let photo = shoot.appendingPathComponent("photo-1.png")
        try files.createDirectory(at: shoot, withIntermediateDirectories: true)
        try Data().write(to: photo)
        let rootFolder = PhotoFolder(root)
        await load(rootFolder)
        let folder = rootFolder.folders[0]
        await load(folder)
        precondition(folder.photos.map(\.lastPathComponent) == [photo.lastPathComponent],
                     "Loaded \(folder.photos.map(\.lastPathComponent)) for \(folder.url.path)")
        let model = MacWorkspaceBrowserState()
        model.browse([rootFolder, folder], load: false)
        precondition(model.containsDirectory(of: photo))
        folder.toggle()
        precondition(!folder.isExpandedInTree)
        let moved = root.appendingPathComponent("Moved")
        try files.moveItem(at: shoot, to: moved)
        folder.refresh()
        await load(folder)
        precondition(folder.error != nil && folder.photos.map(\.lastPathComponent) == [photo.lastPathComponent])
        try files.moveItem(at: moved, to: shoot)
        await load(folder)
        precondition(folder.error == nil && folder.photos.map(\.lastPathComponent) == [photo.lastPathComponent])
        rootFolder.refresh()
        await load(rootFolder)
        precondition(rootFolder.folders.first === folder)
    }

    @MainActor private static func load(_ folder: PhotoFolder) async {
        await withCheckedContinuation { continuation in
            folder.load { continuation.resume() }
        }
    }
}
