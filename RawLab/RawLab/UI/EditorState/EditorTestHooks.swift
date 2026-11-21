import RawLabKit
import SwiftUI

struct EditorPanelLayoutMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let accessibility: Bool
    let buttonWidth: CGFloat
    let buttonHeight: CGFloat
    let scrollTools: Bool
    let sideWidth: CGFloat
    let side: Bool
}

struct EditorTestHooks {
    var onAppear: (@MainActor (ContentView) -> Void)? = nil
    var onDisappear: (@MainActor () -> Void)? = nil
    var onHoldingBeforeChange: (@MainActor (ContentView) -> Void)? = nil
    var onPreviewSizeChange: (@MainActor (Int, @escaping () -> Void) -> Void)? = nil
    var onBatchHandoff: (@MainActor (Bool, ScenePhase) -> Void)? = nil
    var onBatchModelCreated: (@MainActor (BatchExportModel) -> Void)? = nil
    var onPanelLayout: (@MainActor (CGRect, EditorPanelLayoutMetrics) -> Void)? = nil
    var onFineToggleFrame: (@MainActor (CGRect) -> Void)? = nil
    var onGroupTextFrame: (@MainActor (EditorAdjustmentGroup, CGRect) -> Void)? = nil
    var onGroupButtonFrame: (@MainActor (EditorAdjustmentGroup, CGRect, CGFloat) -> Void)? = nil
}

struct OptionalGeometryObserver: ViewModifier {
    let action: ((CGRect) -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { action($0) }
        } else {
            content
        }
    }
}
