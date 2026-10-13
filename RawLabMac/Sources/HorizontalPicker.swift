import SwiftUI

struct HorizontalPickerScrollState: Equatable {
    var contentWidth: CGFloat = 0
    var viewportWidth: CGFloat = 0
    var offset: CGFloat = 0

    var maximumOffset: CGFloat { max(0, contentWidth - viewportWidth) }
    private var clampedOffset: CGFloat { min(max(0, offset), maximumOffset) }
    var canScrollLeft: Bool { clampedOffset > 0.5 }
    var canScrollRight: Bool { maximumOffset - clampedOffset > 0.5 }

    func needsControls(availableWidth: CGFloat) -> Bool {
        contentWidth > availableWidth + 0.5
    }

    func pageOffset(towardTrailing: Bool) -> CGFloat {
        let distance = viewportWidth * 0.85 * (towardTrailing ? 1 : -1)
        return min(max(0, clampedOffset + distance), maximumOffset)
    }
}

struct HorizontalPicker<Content: View>: View {
    @Environment(\.locale) private var localizationLocale
    let selectedID: String
    let name: String
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(idType: String.self)
    @State private var scrollState = HorizontalPickerScrollState()

    init(selectedID: String, name: String, @ViewBuilder content: () -> Content) {
        self.selectedID = selectedID
        self.name = name
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            // 按未扣除箭头的完整宽度判断，内容缩减后不会被两侧按钮困在溢出状态。
            let showsControls = scrollState.needsControls(availableWidth: geometry.size.width)
            let viewportWidth = max(0, geometry.size.width - (showsControls ? 64 : 0))
            HStack(spacing: 0) {
                if showsControls { scrollButton(towardTrailing: false) }
                ScrollView(.horizontal) {
                    content
                        .padding(.bottom, 12)
                        .frame(minWidth: viewportWidth)
                }
                .scrollIndicators(.visible)
                .scrollPosition($position)
                .onScrollGeometryChange(for: HorizontalPickerScrollState.self) { value in
                    HorizontalPickerScrollState(contentWidth: value.contentSize.width,
                                                viewportWidth: value.containerSize.width,
                                                offset: value.contentOffset.x)
                } action: { _, value in
                    scrollState = value
                }
                .onChange(of: selectedID, initial: true) { _, id in
                    position.scrollTo(id: id, anchor: .center)
                }
                if showsControls { scrollButton(towardTrailing: true) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func scrollButton(towardTrailing: Bool) -> some View {
        let enabled = towardTrailing ? scrollState.canScrollRight : scrollState.canScrollLeft
        let title = towardTrailing ? L10n.format("向右滚动%@", String(describing: name)) : L10n.format("向左滚动%@", String(describing: name))
        return Button {
            let target = scrollState.pageOffset(towardTrailing: towardTrailing)
            if reduceMotion { position.scrollTo(x: target) }
            else {
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(x: target) }
            }
        } label: {
            Image(systemName: towardTrailing ? "chevron.right" : "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .opacity(enabled ? 1 : 0.3)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(title)
    }
}
