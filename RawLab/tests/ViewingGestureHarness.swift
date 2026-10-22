import SwiftUI
import UIKit

private struct ViewingProbe: View {
    @State var viewing = PhotoViewingState()
    @State var viewport = PhotoViewport()
    @State var held = 0
    @State var released = 0
    let image: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).image { context in
        UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        UIColor.blue.setFill(); context.fill(CGRect(x: 600, y: 0, width: 600, height: 800))
    }
    var body: some View {
        VStack {
            Text("pure=\(viewing.previewOnly ? 1 : 0) hold=\(viewing.holdingBefore ? 1 : 0) begin=\(held) end=\(released)")
                .accessibilityIdentifier("viewing.state")
            Text("\(viewport.relativeScale)").accessibilityIdentifier("viewing.zoom")
            HStack {
                Button("Compare") { viewing.toggleComparison() }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("viewing.compare")
                Button("Wipe") { viewing.selectMode(.wipe) }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("viewing.wipe")
                Button("Center") { viewing.setSplit(0.5) }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("viewing.center")
            }
            Text("\(viewing.split)").accessibilityIdentifier("viewing.split")
#if VIEWING_BASELINE
            BaselinePhoto(image: image).frame(maxWidth: .infinity, maxHeight: .infinity)
#else
            ZoomablePhoto(image: image, referenceImage: image, label: "Result", viewing: $viewing, viewport: $viewport)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
#endif
        }
        .onChange(of: viewing.holdingBefore) { _, value in if value { held += 1 } else { released += 1 } }
        .preferredColorScheme(.dark)
    }
}
#if VIEWING_BASELINE
private struct BaselinePhoto: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.imageView.image = image
        view.pixels = CGSize(width: 1200, height: 800)
        view.displayScale = 3
    }
}
#endif
private final class ViewingAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Viewing", sessionRole: session.role)
        config.delegateClass = ViewingScene.self
        return config
    }
}
private final class ViewingScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene)
        window.rootViewController = UIHostingController(rootView: ViewingProbe())
        window.makeKeyAndVisible()
        self.window = window
    }
}
@main enum ViewingMain {
    static func main() { UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ViewingAppDelegate.self)) }
}
