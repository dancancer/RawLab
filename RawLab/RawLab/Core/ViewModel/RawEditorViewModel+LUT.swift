import Foundation

struct LUTOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct LUTReference {
    let id: String
    let name: String
    let sourceURL: URL
}

extension RawEditorViewModel {
    func loadLUTsIfNeeded() {
        guard !isLoadingLUTs, availableLUTs.isEmpty else {
            return
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            return
        }

        isLoadingLUTs = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = self.loadBundledLUTs(from: resourceURL)
            DispatchQueue.main.async {
                self.availableLUTs = result.options
                self.lutMap = result.map
                self.isLoadingLUTs = false
            }
        }
    }

    func lutURL(for settings: RawSettings) -> URL? {
        guard let lutID = settings.lutID else {
            return nil
        }
        return lutMap[lutID]?.sourceURL
    }
}

extension RawEditorViewModel {
    func loadBundledLUTs(from resourceURL: URL) -> (options: [LUTOption], map: [String: LUTReference]) {
        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(at: resourceURL, includingPropertiesForKeys: nil)
        var urls: [URL] = []

        while let fileURL = enumerator?.nextObject() as? URL {
            if fileURL.pathExtension.lowercased() == "cube" {
                urls.append(fileURL)
            }
        }

        let sorted = urls.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        var options: [LUTOption] = []
        var map: [String: LUTReference] = [:]

        for url in sorted {
            let fileName = url.deletingPathExtension().lastPathComponent
            guard isFLog2LUTName(fileName) else {
                continue
            }
            let displayName = prettifyLUTName(fileName)
            options.append(LUTOption(id: fileName, name: displayName))
            map[fileName] = LUTReference(id: fileName, name: displayName, sourceURL: url)
        }

        return (options, map)
    }

    func isFLog2LUTName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let isInput = lower.contains("f-log2") || lower.contains("flog2")
        let isLogOutput = lower.contains("to_flog2") || lower.contains("to_f-log2")
        return isInput && !isLogOutput && !lower.contains("flog2c")
    }

    func prettifyLUTName(_ name: String) -> String {
        FilmPresentation(fileName: name).name
    }
}
