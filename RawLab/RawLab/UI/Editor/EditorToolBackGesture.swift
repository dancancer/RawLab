import SwiftUI
import UIKit

// 工具工作区与主页共用 NavigationStack 根视图，边缘返回必须先经过草稿守卫。
struct EditorToolBackGesture: UIViewControllerRepresentable {
    let enabled: Bool
    let onBack: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onBack = onBack
        controller.edgePan.isEnabled = enabled
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.detachGesture()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var onBack: () -> Void = {}
        lazy var edgePan: UIScreenEdgePanGestureRecognizer = {
            let gesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleBack(_:)))
            gesture.edges = .left
            gesture.maximumNumberOfTouches = 1
            gesture.delegate = self
            return gesture
        }()

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            detachGesture()
            // 监听工作区宿主，才能在画布收到触摸时参与竞争；不添加覆盖画布的触摸层。
            parent?.view.addGestureRecognizer(edgePan)
        }

        func detachGesture() {
            edgePan.view?.removeGestureRecognizer(edgePan)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = edgePan.velocity(in: edgePan.view)
            return velocity.x > abs(velocity.y)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // 左缘返回先于画布平移／裁切拖动判定；非边缘拖动会立即交还原手势。
            otherGestureRecognizer is UIPanGestureRecognizer && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer)
        }

        @objc private func handleBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let distance = gesture.translation(in: gesture.view).x
            let velocity = gesture.velocity(in: gesture.view).x
            guard distance > 80 || (distance > 0 && velocity > 500) else { return }
            onBack()
        }
    }
}
