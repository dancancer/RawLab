import Foundation

@main
struct RUMTransportTests {
    static func main() {
        guard !RawLabIOSUsageTransport.allowsRestart else {
            fatalError("iOS RUM stop must not be silently restarted in the same process")
        }
        // 不带 SDK 的构建（调试构建默认如此）必须不可用，即使给了正式配置
        let production = try? RUMConfiguration.production(environment: [:])
        let transport = RawLabIOSUsageTransport.make(configuration: production, deviceID: { UUID().uuidString })
        guard !transport.isAvailable else { fatalError("a build without the SDK must not expose RUM") }
        do {
            try transport.start()
            fatalError("the default iOS transport unexpectedly started")
        } catch {
            print("PASS: an iOS build without the SDK keeps RUM unavailable")
        }
    }
}
