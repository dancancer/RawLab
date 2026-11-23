import Darwin
import Foundation

/// Watches target store files (such as `edits.json` and `presets.json`) across missing
/// directories and atomic inode replacements (`os.replace` / `.atomic`), debouncing
/// filesystem churn and gating notifications on `FileStatFingerprint` changes.
public final class ExternalStoreFileWatcher: @unchecked Sendable {
    public struct WatchTarget: Hashable {
        public let url: URL

        public init(url: URL) {
            self.url = url.standardizedFileURL
        }
    }

    private struct ActiveSource {
        let fd: Int32
        let source: DispatchSourceFileSystemObject
        let inode: UInt64?
    }

    private let targets: [URL]
    private let debounceInterval: TimeInterval
    private let watchQueue = DispatchQueue(label: "rawlab.external-store-watcher")
    private let callbackQueue: DispatchQueue
    private let onChange: (URL) -> Void

    private var activeSources: [String: ActiveSource] = [:]
    private var lastFingerprints: [String: FileStatFingerprint?] = [:]
    private var pendingDebounce: DispatchWorkItem?
    private var stopped = false

    public init(
        urls: [URL],
        debounceInterval: TimeInterval = 0.05,
        callbackQueue: DispatchQueue = .main,
        onChange: @escaping (URL) -> Void
    ) {
        var unique: [URL] = []
        var seen = Set<String>()
        for url in urls {
            let normalized = Self.canonicalTargetPath(for: url)
            if seen.insert(normalized).inserted {
                unique.append(url)
            }
        }
        self.targets = unique
        self.debounceInterval = max(0.01, debounceInterval)
        self.callbackQueue = callbackQueue
        self.onChange = onChange

        watchQueue.sync {
            for url in targets {
                let path = Self.canonicalTargetPath(for: url)
                lastFingerprints[path] = FileStatFingerprint(resolvedPath: path)
            }
            refreshWatchesLocked()
        }
    }

    deinit {
        stop()
    }

    public func stop() {
        watchQueue.sync {
            guard !stopped else { return }
            stopped = true
            pendingDebounce?.cancel()
            pendingDebounce = nil
            for entry in activeSources.values {
                entry.source.cancel()
            }
            activeSources.removeAll()
        }
    }

    public func refresh() {
        watchQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.refreshWatchesLocked()
        }
    }

    public static func canonicalTargetPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(standardized.lastPathComponent).path
    }

    private func desiredWatchPathsLocked() -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default

        for url in targets {
            let filePath = Self.canonicalTargetPath(for: url)
            if fm.fileExists(atPath: filePath), seen.insert(filePath).inserted {
                paths.append(filePath)
            }

            // Watch parent directory if present, otherwise walk up to nearest existing ancestor.
            var cursor = URL(fileURLWithPath: filePath).deletingLastPathComponent()
            while cursor.path != "/" {
                let candidate = cursor.resolvingSymlinksInPath().standardizedFileURL.path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                    if seen.insert(candidate).inserted {
                        paths.append(candidate)
                    }
                    break
                }
                cursor = cursor.deletingLastPathComponent()
            }
        }
        return paths
    }

    private func refreshWatchesLocked() {
        let desired = Set(desiredWatchPathsLocked())
        let currentKeys = Set(activeSources.keys)

        for removed in currentKeys.subtracting(desired) {
            activeSources.removeValue(forKey: removed)?.source.cancel()
        }

        for path in desired {
            let currentInode = FileStatFingerprint(resolvedPath: path)?.inode
            if let existing = activeSources[path] {
                if existing.inode == currentInode {
                    continue
                }
                existing.source.cancel()
                activeSources.removeValue(forKey: path)
            }
            openWatchLocked(atPath: path, inode: currentInode)
        }
    }

    private func openWatchLocked(atPath path: String, inode: UInt64?) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.refreshWatchesLocked()
            self.scheduleEvaluationLocked()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        activeSources[path] = ActiveSource(fd: fd, source: source, inode: inode)
        source.resume()
    }

    private func scheduleEvaluationLocked() {
        pendingDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.pendingDebounce = nil
            self.refreshWatchesLocked()
            self.evaluateChangesLocked()
        }
        pendingDebounce = work
        watchQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func evaluateChangesLocked() {
        var changed: [URL] = []
        for url in targets {
            let path = Self.canonicalTargetPath(for: url)
            let current = FileStatFingerprint(resolvedPath: path)
            let previous = lastFingerprints[path] ?? nil
            if current != previous {
                lastFingerprints[path] = current
                changed.append(url)
            }
        }
        guard !changed.isEmpty else { return }
        callbackQueue.async { [onChange] in
            for url in changed {
                onChange(url)
            }
        }
    }
}
