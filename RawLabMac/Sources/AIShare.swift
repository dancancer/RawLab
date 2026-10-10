import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AIShareFileProvider {
    private let source: URL
    private let name: String
    private let owner: AnyObject?
    private let queue = DispatchQueue(label: "rawlab.ai.share", qos: .userInitiated)
    private var directory: AITemporaryDirectory?
    private var file: URL?

    init(source: URL, name: String, owner: AnyObject? = nil) {
        self.source = source; self.name = name; self.owner = owner
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = AIColorLook.fileName(name)
        // 系统持有 provider 时同时持有文件所有者，关闭仿色面板不会提前移除正在分享的文件。
        provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { [self] completion in
            let progress = Progress(totalUnitCount: 1)
            queue.async(execute: DispatchWorkItem {
                do {
                    if progress.isCancelled { throw CancellationError() }
                    if self.file == nil {
                        let directory = try AITemporaryDirectory()
                        let file = directory.url.appendingPathComponent(AIColorLook.fileName(self.name))
                        try withExtendedLifetime(self.owner) {
                            try AIFileExporter.write(source: self.source, destination: file, protecting: [], overwrite: false)
                        }
                        self.directory = directory; self.file = file
                    }
                    if progress.isCancelled { throw CancellationError() }
                    progress.completedUnitCount = 1
                    completion(self.file, false, nil)
                } catch { completion(nil, false, error) }
            })
            return progress
        }
        return provider
    }
}

@MainActor private final class AIShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private static var active: [UUID: AIShareSession] = [:]
    private let id = UUID()
    private let picker: NSSharingServicePicker
    private let onError: (String) -> Void

    init(source: URL, name: String, owner: AnyObject?, onError: @escaping (String) -> Void) {
        let provider = AIShareFileProvider(source: source, name: name, owner: owner).itemProvider()
        picker = NSSharingServicePicker(items: [provider])
        self.onError = onError
        super.init()
        picker.delegate = self
    }

    func show(from view: NSView) {
        Self.active[id] = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? { self }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish() }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        if (error as NSError).code != NSUserCancelledError { onError("系统分享未完成，请重试或导出 CUBE 文件。") }
        finish()
    }
    private func finish() { Self.active.removeValue(forKey: id) }
}

struct AIShareButton: NSViewRepresentable {
    let source: URL
    let name: String
    var owner: AnyObject? = nil
    var enabled = true
    var onError: (String) -> Void

    final class Coordinator: NSObject {
        var parent: AIShareButton
        init(_ parent: AIShareButton) { self.parent = parent }
        @MainActor @objc func share(_ sender: NSButton) {
            guard parent.enabled else { return }
            AIShareSession(source: parent.source, name: parent.name, owner: parent.owner, onError: parent.onError).show(from: sender)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "分享 CUBE")!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        button.sendAction(on: .leftMouseDown)
        button.toolTip = "分享 CUBE · 原始外观 100% · 显示 sRGB"
        button.setAccessibilityLabel("分享 CUBE")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.isEnabled = enabled
    }
}

@MainActor enum AICubeActions {
    static func export(source: URL, name: String, protecting: [URL], owner: AnyObject? = nil,
                       onError: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.title = "导出 CUBE"
        panel.message = "原始外观 100% · 显示 sRGB 输入/输出 · 不含照片曝光、白平衡与后续调整"
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = AIColorLook.fileName(name)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let overwrite = FileManager.default.fileExists(atPath: destination.path)
        Task {
            do {
                try await AIColorWorker().perform {
                    try withExtendedLifetime(owner) {
                        try AIFileExporter.write(source: source, destination: destination, protecting: protecting, overwrite: overwrite)
                    }
                }
            } catch { onError(error.localizedDescription) }
        }
    }
}
