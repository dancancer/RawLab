import Foundation

@main
struct RUMLocalTransportTests {
    static func main() {
        guard !RawLabIOSUsageTransport.allowsRestart else {
            fatalError("iOS RUM stop must not be silently restarted in the same process")
        }
        let transport = RawLabIOSUsageTransport.make(configuration: nil)
        guard !transport.isAvailable else { fatalError("the default iOS build must not expose the RUM SDK") }
        do {
            try transport.start()
            fatalError("the default iOS transport unexpectedly started")
        } catch {
            print("PASS: default iOS build keeps RUM unavailable")
        }
    }
}
