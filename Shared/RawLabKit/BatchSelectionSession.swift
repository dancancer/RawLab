import Foundation

// 集合只管理导航和选择；草稿决定、冻结 payload 与导出快照由每次操作持有。
public struct BatchSelectionSession<Identity: Hashable> {
    public private(set) var ordered: [Identity] = []
    public private(set) var selected: Set<Identity> = []
    public private(set) var current: Identity?
    public private(set) var returnPosition: Identity?
    public private(set) var lastSynchronization: UUID?

    public init() {}

    public mutating func append(_ identities: [Identity]) {
        var known = Set(ordered)
        for identity in identities where known.insert(identity).inserted {
            ordered.append(identity)
            selected.insert(identity)
        }
    }

    public mutating func select(_ identity: Identity, _ value: Bool) {
        guard ordered.contains(identity) else { return }
        if value { selected.insert(identity) } else { selected.remove(identity) }
    }

    public mutating func selectAll(_ value: Bool) { selected = value ? Set(ordered) : [] }

    public mutating func remove(_ identity: Identity) {
        ordered.removeAll { $0 == identity }; selected.remove(identity)
        if current == identity { current = nil }
        if returnPosition == identity { returnPosition = nil }
    }

    @discardableResult public mutating func beginEditing(_ identity: Identity) -> Bool {
        guard ordered.contains(identity) else { return false }
        current = identity; returnPosition = identity
        return true
    }

    public mutating func returnToCollection() { current = nil }

    public func targets(excluding source: Identity? = nil) -> [Identity] {
        ordered.filter { selected.contains($0) && $0 != source }
    }

    public mutating func recordSynchronization(_ id: UUID, changed: Bool) {
        if changed { lastSynchronization = id }
    }
}
