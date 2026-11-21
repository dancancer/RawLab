import Foundation

public enum RenderPass: Equatable, Sendable {
    case interactive
    case exact
}

public struct RenderRequest<Value: Equatable>: Equatable {
    public let id: Int
    public let fileID: String
    public let pass: RenderPass
    public let value: Value

    public init(id: Int, fileID: String, pass: RenderPass, value: Value) {
        self.id = id
        self.fileID = fileID
        self.pass = pass
        self.value = value
    }
}

public enum RenderCompletion: Equatable, Sendable {
    case publishInteractive
    case publishExact
    case discard
    case ignored
}

/// Main-thread state for a latest-only render queue. The executor owns at most
/// one in-flight request; a newer request replaces the single pending slot.
public struct RenderScheduler<Value: Equatable> {
    public private(set) var interacting = false
    public private(set) var latest: RenderRequest<Value>?
    public private(set) var pending: RenderRequest<Value>?
    public private(set) var inFlight: RenderRequest<Value>?
    private var nextID = 0
    private var publishedExactID = 0
    private var invalidatedThroughID = 0

    public init() {}

    public var isBusy: Bool { interacting || pending != nil || inFlight != nil }
    public var hasPending: Bool { pending != nil }

    public mutating func setInteracting(_ value: Bool) {
        interacting = value
    }

    public mutating func invalidatePending() {
        invalidatedThroughID = nextID
        latest = nil
        pending = nil
    }

    public mutating func submit(_ value: Value, fileID: String) -> RenderRequest<Value> {
        submit(value, fileID: fileID, pass: interacting ? .interactive : .exact)
    }

    public mutating func submit(_ value: Value, fileID: String, pass: RenderPass) -> RenderRequest<Value> {
        nextID += 1
        let request = RenderRequest(id: nextID, fileID: fileID, pass: pass, value: value)
        latest = request
        pending = request
        return request
    }

    public mutating func startNext() -> RenderRequest<Value>? {
        guard inFlight == nil, let request = pending else { return nil }
        pending = nil
        inFlight = request
        return request
    }

    public mutating func finish(_ request: RenderRequest<Value>) -> RenderCompletion {
        guard inFlight?.id == request.id else { return .ignored }
        inFlight = nil

        guard request.id > invalidatedThroughID, latest?.fileID == request.fileID else { return .discard }
        switch request.pass {
        case .interactive:
            guard publishedExactID < request.id else { return .discard }
            return .publishInteractive
        case .exact:
            guard latest?.id == request.id else { return .discard }
            publishedExactID = request.id
            return .publishExact
        }
    }
}
