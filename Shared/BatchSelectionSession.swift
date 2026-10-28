import Foundation

// 集合只管理导航和选择；草稿决定、冻结 payload 与导出快照由每次操作持有。
struct BatchSelectionSession<Identity: Hashable> {
    private(set) var ordered: [Identity] = []
    private(set) var selected: Set<Identity> = []
    private(set) var current: Identity?
    private(set) var returnPosition: Identity?
    private(set) var lastSynchronization: UUID?

    mutating func append(_ identities: [Identity]) {
        var known = Set(ordered)
        for identity in identities where known.insert(identity).inserted {
            ordered.append(identity)
            selected.insert(identity)
        }
    }

    mutating func select(_ identity: Identity, _ value: Bool) {
        guard ordered.contains(identity) else { return }
        if value { selected.insert(identity) } else { selected.remove(identity) }
    }

    mutating func selectAll(_ value: Bool) { selected = value ? Set(ordered) : [] }

    mutating func remove(_ identity: Identity) {
        ordered.removeAll { $0 == identity }; selected.remove(identity)
        if current == identity { current = nil }
        if returnPosition == identity { returnPosition = nil }
    }

    @discardableResult mutating func beginEditing(_ identity: Identity) -> Bool {
        guard ordered.contains(identity) else { return false }
        current = identity; returnPosition = identity
        return true
    }

    mutating func returnToCollection() { current = nil }

    func targets(excluding source: Identity? = nil) -> [Identity] {
        ordered.filter { selected.contains($0) && $0 != source }
    }

    mutating func recordSynchronization(_ id: UUID, changed: Bool) {
        if changed { lastSynchronization = id }
    }
}
