import Foundation

@main
struct RUMThreadingTests {
    static func main() {
        let firstViewID = RawLabRUMViewContext.makeID()
        let secondViewID = RawLabRUMViewContext.makeID()
        guard RawLabRUMViewContext.name == "RawLab Usage",
              RawLabRUMViewContext.method == "manual",
              RawLabRUMViewContext.type == nil,
              firstViewID.hasPrefix("rawlab-usage-"),
              firstViewID != secondViewID else {
            fatalError("local RUM must use a synthetic logical view context")
        }

        let finished = DispatchSemaphore(value: 0)
        var ranOnMain = false
        DispatchQueue.global(qos: .utility).async {
            RawLabRUMThreading.onMain {
                ranOnMain = Thread.isMainThread
                finished.signal()
            }
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while finished.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        guard ranOnMain else {
            fatalError("RUM SDK lifecycle work was not marshalled to the main thread")
        }
        print("PASS: iOS RUM start lifecycle can satisfy the SDK main-thread requirement")
    }
}
