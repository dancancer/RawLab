import Foundation

struct LUTOption: Identifiable, Hashable {
    let id: String
    let name: String
}

struct LUTReference {
    let id: String
    let name: String
    let sourceURL: URL
    let isCustom: Bool

    init(id: String, name: String, sourceURL: URL, isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.sourceURL = sourceURL
        self.isCustom = isCustom
    }
}

extension RawEditorViewModel {
    func loadLUTsIfNeeded() {
        guard !didStartLUTLoad, !isLoadingLUTs else { return }
        didStartLUTLoad = true
        isLoadingLUTs = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let bundled = Bundle.main.resourceURL.map(self.loadBundledLUTs)
                ?? (options: [], map: [:])
            self.lookImportCoordinator.load { result in
                self.resultDelivery {
                    switch result {
                    case .success(let managedLooks):
                        let custom = self.customLUTs(from: managedLooks)
                        self.availableLUTs = bundled.options + custom.options
                        self.lutMap = bundled.map.merging(custom.map) { _, custom in custom }
                    case .failure(let reason):
                        self.availableLUTs = bundled.options
                        self.lutMap = bundled.map
                        self.statusMessage = reason.localizedDescription
                    }
                    self.includeIndependentRecipeLook(self.currentPreviewSettings)
                    self.isLoadingLUTs = false
                }
            }
        }
    }

    func importLooks(from sources: [URL], completion: @escaping (LookImportBatchResult) -> Void) {
        guard !sources.isEmpty else {
            completion(LookImportBatchResult(imported: [], failures: []))
            return
        }
        isImportingLooks = true
        lookImportCoordinator.importLooks(from: sources) { [weak self] result in
            guard let self else { return }
            self.resultDelivery {
                let custom = self.customLUTs(from: result.imported)
                self.availableLUTs.append(contentsOf: custom.options)
                self.lutMap.merge(custom.map) { _, custom in custom }
                self.isImportingLooks = false
                completion(result)
            }
        }
    }

    func lutURL(for settings: RawSettings) -> URL? {
        if let id = settings.masterRecipeID { return MasterRecipe.recipe(for: id)?.lutURL() }
        guard let lutID = settings.lutID else {
            return nil
        }
        if lutID.hasPrefix("recipe-lut:") { return MasterRecipe.recipe(for: String(lutID.dropFirst("recipe-lut:".count)))?.lutURL() }
        return lutMap[lutID]?.sourceURL
    }

    func includeIndependentRecipeLook(_ settings: RawSettings) {
        guard let id = settings.lutID, id.hasPrefix("recipe-lut:"),
              let recipe = MasterRecipe.recipe(for: String(id.dropFirst("recipe-lut:".count))),
              let url = recipe.lutURL(), FileManager.default.isReadableFile(atPath: url.path),
              !availableLUTs.contains(where: { $0.id == id }) else { return }
        availableLUTs.append(.init(id: id, name: L10n.text(recipe.name)))
    }

    func isLookAvailable(for settings: RawSettings) -> Bool {
        guard settings.hasLook else { return true }
        guard let url = lutURL(for: settings) else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
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
            guard isFLog2LUTName(fileName) || BundledLook.find(fileName) != nil else {
                continue
            }
            let displayName = prettifyLUTName(fileName)
            options.append(LUTOption(id: fileName, name: displayName))
            map[fileName] = LUTReference(id: fileName, name: displayName, sourceURL: url)
        }

        return (options, map)
    }

    private func customLUTs(from looks: [ManagedLook]) -> (options: [LUTOption], map: [String: LUTReference]) {
        var options: [LUTOption] = []
        var map: [String: LUTReference] = [:]
        for managed in looks {
            let id = managed.record.id
            let name = managed.record.name
            options.append(LUTOption(id: id, name: name))
            map[id] = LUTReference(id: id, name: name, sourceURL: managed.url, isCustom: true)
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
