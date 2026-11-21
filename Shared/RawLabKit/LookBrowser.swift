import Foundation

public enum LookBrowserCategory: String, CaseIterable {
    case all, fuji, kodak, other, custom, recent

    public var titleKey: String {
        switch self {
        case .all: return "全部外观"
        case .fuji: return "Fuji"
        case .kodak: return "Kodak"
        case .other: return "其他"
        case .custom: return "用户外观"
        case .recent: return "最近使用"
        }
    }
}

public struct LookBrowserItem: Identifiable {
    public let id: String
    public let name: String
    public let group: FilmGroup
    public let isCustom: Bool

    public init(id: String, name: String, group: FilmGroup, isCustom: Bool) {
        self.id = id
        self.name = name
        self.group = group
        self.isCustom = isCustom
    }
}

public struct LookBrowserState: Equatable {
    public var category: LookBrowserCategory = .all
    public var query = ""

    public init(category: LookBrowserCategory = .all, query: String = "") {
        self.category = category
        self.query = query
    }

    public func visibleIDs(in items: [LookBrowserItem], recent: [String]) -> [String] {
        let term = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let matching = items.filter { item in
            guard term.isEmpty || normalized(item.name).contains(term) else { return false }
            switch category {
            case .all, .recent: return true
            case .custom: return item.isCustom
            case .fuji: return !item.isCustom && item.group == .fuji
            case .kodak: return !item.isCustom && item.group == .kodak
            case .other: return item.group == .other
            }
        }
        if category == .recent {
            let available = Set(matching.map(\.id))
            return recent.filter(available.contains)
        }
        return matching.map(\.id)
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

public struct RecentLooks: Equatable {
    public private(set) var ids: [String]

    public init(ids: [String] = []) {
        var seen = Set<String>()
        self.ids = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(12))
    }

    public mutating func record(_ id: String, available: Set<String>) {
        guard !id.isEmpty, available.contains(id) else { return }
        self = RecentLooks(ids: [id] + ids.filter { $0 != id && available.contains($0) })
    }

    public mutating func prune(available: Set<String>) { ids.removeAll { !available.contains($0) } }

    public static func load(from url: URL) -> RecentLooks {
        guard let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode([String].self, from: data) else { return RecentLooks() }
        return RecentLooks(ids: ids)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }
}
