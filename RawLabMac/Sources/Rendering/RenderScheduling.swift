import Foundation

enum RenderPass: Equatable {
    case interactive
    case exact
}

struct RenderRequest<Value: Equatable>: Equatable {
    let id: Int
    let fileID: String
    let pass: RenderPass
    let value: Value
}

enum RenderCompletion: Equatable {
    case publishInteractive
    case publishExact
    case discard
    case ignored
}

/// Main-thread state for a latest-only render queue. The executor owns at most
/// one in-flight request; a newer request replaces the single pending slot.
struct RenderScheduler<Value: Equatable> {
    private(set) var interacting = false
    private(set) var latest: RenderRequest<Value>?
    private(set) var pending: RenderRequest<Value>?
    private(set) var inFlight: RenderRequest<Value>?
    private var nextID = 0
    private var publishedExactID = 0

    var isBusy: Bool { interacting || pending != nil || inFlight != nil }
    var hasPending: Bool { pending != nil }

    mutating func setInteracting(_ value: Bool) {
        interacting = value
    }

    mutating func submit(_ value: Value, fileID: String) -> RenderRequest<Value> {
        submit(value, fileID: fileID, pass: interacting ? .interactive : .exact)
    }

    mutating func submit(_ value: Value, fileID: String, pass: RenderPass) -> RenderRequest<Value> {
        nextID += 1
        let request = RenderRequest(id: nextID, fileID: fileID, pass: pass, value: value)
        latest = request
        pending = request
        return request
    }

    mutating func startNext() -> RenderRequest<Value>? {
        guard inFlight == nil, let request = pending else { return nil }
        pending = nil
        inFlight = request
        return request
    }

    mutating func finish(_ request: RenderRequest<Value>) -> RenderCompletion {
        guard inFlight?.id == request.id else { return .ignored }
        inFlight = nil

        guard latest?.fileID == request.fileID else { return .discard }
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
