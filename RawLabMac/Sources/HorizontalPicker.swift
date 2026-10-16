import AppKit
import QuartzCore
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

struct HorizontalPickerScrollRequest: Equatable {
    let sequence: Int
    let offset: CGFloat
    let animated: Bool
}

// MARK: - Native scroll bridge

/// A zero-size AppKit view that remains inside the SwiftUI scroll document.
/// Its superview chain is the reliable way to find the native scroll view.
final class HorizontalPickerScrollBridgeView: NSView {
    weak var coordinator: HorizontalPickerScrollBridgeCoordinator?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        coordinator?.scheduleRefresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.scheduleRefresh()
    }

    override func layout() {
        super.layout()
        coordinator?.scheduleRefresh()
    }
}

final class HorizontalPickerScrollBridgeCoordinator {
    typealias StateHandler = (HorizontalPickerScrollState) -> Void

    private var stateHandler: StateHandler?
    private weak var bridgeView: HorizontalPickerScrollBridgeView?
    private weak var observedScrollView: NSScrollView?
    private weak var observedClipView: NSClipView?
    private weak var observedDocumentView: NSView?
    private var notificationTokens: [NSObjectProtocol] = []
    private var documentViewObservation: NSKeyValueObservation?
    private var contentViewObservation: NSKeyValueObservation?

    private var originalScrollPostsFrame: Bool?
    private var originalClipPostsBounds: Bool?
    private var originalClipPostsFrame: Bool?
    private var originalDocumentPostsFrame: Bool?

    private var refreshScheduled = false
    private var rebindTimer: Timer?
    private var generation = 0
    private var reportSequence = 0
    private var active = false
    private var lastState: HorizontalPickerScrollState?
    private var pendingRequest: HorizontalPickerScrollRequest?
    private var lastRequestSequence: Int?

    init(onStateChange: @escaping StateHandler) {
        stateHandler = onStateChange
    }

    func update(onStateChange: @escaping StateHandler, request: HorizontalPickerScrollRequest?) {
        stateHandler = onStateChange
        if let request {
            apply(request)
        }
    }

    func attach(to view: HorizontalPickerScrollBridgeView) {
        unbindNativeViews()
        generation &+= 1
        active = true
        bridgeView = view
        view.coordinator = self
        startRebindTimer()
        scheduleRefresh()
    }

    func apply(_ request: HorizontalPickerScrollRequest) {
        guard active, lastRequestSequence != request.sequence else { return }
        lastRequestSequence = request.sequence
        pendingRequest = request
        scheduleRefresh()
    }

    func scheduleRefresh() {
        guard active, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func teardown() {
        active = false
        generation &+= 1
        reportSequence &+= 1
        refreshScheduled = false
        pendingRequest = nil
        rebindTimer?.invalidate()
        rebindTimer = nil
        unbindNativeViews()
        bridgeView?.coordinator = nil
        bridgeView = nil
        stateHandler = nil
    }

    private func startRebindTimer() {
        rebindTimer?.invalidate()
        // AppKit can replace a clip view without posting a KVO or frame notification.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.scheduleRefresh()
        }
        timer.tolerance = 0.05
        rebindTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    private func refresh() {
        guard active, let bridgeView else { return }
        guard let scrollView = enclosingScrollView(of: bridgeView) else { return }

        let clipView = scrollView.contentView
        let documentView = scrollView.documentView
        if observedScrollView !== scrollView || observedClipView !== clipView || observedDocumentView !== documentView {
            bindNativeViews(scrollView: scrollView, clipView: clipView, documentView: documentView)
        }

        reportState()
        if let request = pendingRequest {
            pendingRequest = nil
            perform(request, in: clipView, scrollView: scrollView)
        }
    }

    private func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var ancestor: NSView? = view
        while let current = ancestor {
            if let scrollView = current as? NSScrollView { return scrollView }
            ancestor = current.superview
        }
        return nil
    }

    private func bindNativeViews(scrollView: NSScrollView, clipView: NSClipView, documentView: NSView?) {
        unbindNativeViews()
        generation &+= 1
        lastState = nil
        observedScrollView = scrollView
        observedClipView = clipView
        observedDocumentView = documentView

        originalScrollPostsFrame = scrollView.postsFrameChangedNotifications
        originalClipPostsBounds = clipView.postsBoundsChangedNotifications
        originalClipPostsFrame = clipView.postsFrameChangedNotifications
        originalDocumentPostsFrame = documentView?.postsFrameChangedNotifications

        scrollView.postsFrameChangedNotifications = true
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        documentView?.postsFrameChangedNotifications = true

        observe(NSView.boundsDidChangeNotification, object: clipView)
        observe(NSView.frameDidChangeNotification, object: scrollView)
        observe(NSView.frameDidChangeNotification, object: clipView)
        if let documentView {
            observe(NSView.frameDidChangeNotification, object: documentView)
        }

        documentViewObservation = scrollView.observe(\NSScrollView.documentView, options: [.new]) { [weak self] _, _ in
            self?.scheduleRefresh()
        }
        contentViewObservation = scrollView.observe(\NSScrollView.contentView, options: [.new]) { [weak self] _, _ in
            self?.scheduleRefresh()
        }
    }

    private func observe(_ name: Notification.Name, object: Any) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            self?.scheduleRefresh()
        }
        notificationTokens.append(token)
    }

    private func unbindNativeViews() {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        documentViewObservation?.invalidate()
        documentViewObservation = nil
        contentViewObservation?.invalidate()
        contentViewObservation = nil

        if let scrollView = observedScrollView, let originalScrollPostsFrame {
            scrollView.postsFrameChangedNotifications = originalScrollPostsFrame
        }
        if let clipView = observedClipView {
            if let originalClipPostsBounds {
                clipView.postsBoundsChangedNotifications = originalClipPostsBounds
            }
            if let originalClipPostsFrame {
                clipView.postsFrameChangedNotifications = originalClipPostsFrame
            }
        }
        if let documentView = observedDocumentView, let originalDocumentPostsFrame {
            documentView.postsFrameChangedNotifications = originalDocumentPostsFrame
        }

        observedScrollView = nil
        observedClipView = nil
        observedDocumentView = nil
        originalScrollPostsFrame = nil
        originalClipPostsBounds = nil
        originalClipPostsFrame = nil
        originalDocumentPostsFrame = nil
    }

    private func reportState() {
        guard let clipView = observedClipView else { return }
        let state = HorizontalPickerScrollState(
            contentWidth: observedDocumentView?.bounds.width ?? 0,
            viewportWidth: max(0, clipView.bounds.width),
            offset: clipView.bounds.origin.x
        )
        guard lastState != state else { return }
        lastState = state

        reportSequence &+= 1
        let reportSequence = self.reportSequence
        let generation = self.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.generation == generation,
                  self.reportSequence == reportSequence else { return }
            self.stateHandler?(state)
        }
    }

    private func perform(_ request: HorizontalPickerScrollRequest, in clipView: NSClipView, scrollView: NSScrollView) {
        let maximumOffset = max(0, (observedDocumentView?.bounds.width ?? 0) - clipView.bounds.width)
        let target = min(max(0, request.offset), maximumOffset)
        var origin = clipView.bounds.origin
        origin.x = target

        if request.animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipView.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                guard let self, self.active else { return }
                scrollView.reflectScrolledClipView(clipView)
                self.scheduleRefresh()
            }
        } else {
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            scheduleRefresh()
        }
    }
}

private struct HorizontalPickerScrollBridge: NSViewRepresentable {
    let request: HorizontalPickerScrollRequest?
    let onStateChange: (HorizontalPickerScrollState) -> Void

    func makeCoordinator() -> HorizontalPickerScrollBridgeCoordinator {
        HorizontalPickerScrollBridgeCoordinator(onStateChange: onStateChange)
    }

    func makeNSView(context: Context) -> HorizontalPickerScrollBridgeView {
        let view = HorizontalPickerScrollBridgeView(frame: .zero)
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: HorizontalPickerScrollBridgeView, context: Context) {
        context.coordinator.update(onStateChange: onStateChange, request: request)
    }

    static func dismantleNSView(_ nsView: HorizontalPickerScrollBridgeView, coordinator: HorizontalPickerScrollBridgeCoordinator) {
        coordinator.teardown()
    }
}

// MARK: - Picker view

struct HorizontalPicker<Content: View>: View {
    @Environment(\.locale) private var localizationLocale
    let selectedID: String
    let name: String
    let showsScrollIndicators: Bool
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollState = HorizontalPickerScrollState()
    @State private var scrollRequestSequence = 0
    @State private var scrollRequest: HorizontalPickerScrollRequest?

    init(selectedID: String, name: String, showsScrollIndicators: Bool = true, @ViewBuilder content: () -> Content) {
        self.selectedID = selectedID
        self.name = name
        self.showsScrollIndicators = showsScrollIndicators
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            // Use the full width before reserving arrow lanes so shrinking content can hide them.
            let showsControls = scrollState.needsControls(availableWidth: geometry.size.width)
            let viewportWidth = max(0, geometry.size.width - (showsControls ? 64 : 0))
            HStack(spacing: 0) {
                if showsControls { scrollButton(towardTrailing: false) }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: showsScrollIndicators) {
                        content
                            .padding(.bottom, showsScrollIndicators ? 12 : 0)
                            .frame(minWidth: viewportWidth)
                            .background(
                                HorizontalPickerScrollBridge(request: scrollRequest) { value in
                                    if scrollState != value {
                                        scrollState = value
                                    }
                                }
                                .allowsHitTesting(false)
                            )
                    }
                    .onAppear {
                        scrollToSelectedID(using: proxy)
                    }
                    .onChange(of: selectedID) { _, _ in
                        scrollToSelectedID(using: proxy)
                    }
                    .onChange(of: scrollState.viewportWidth) { _, _ in
                        scrollToSelectedID(using: proxy)
                    }
                    .onChange(of: scrollState.contentWidth) { _, _ in
                        scrollToSelectedID(using: proxy)
                    }
                }
                if showsControls { scrollButton(towardTrailing: true) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func scrollToSelectedID(using proxy: ScrollViewProxy) {
        let id = selectedID
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func scrollButton(towardTrailing: Bool) -> some View {
        let enabled = towardTrailing ? scrollState.canScrollRight : scrollState.canScrollLeft
        let title = towardTrailing ? L10n.format("向右滚动%@", String(describing: name)) : L10n.format("向左滚动%@", String(describing: name))
        return Button {
            scrollRequestSequence += 1
            scrollRequest = HorizontalPickerScrollRequest(
                sequence: scrollRequestSequence,
                offset: scrollState.pageOffset(towardTrailing: towardTrailing),
                animated: !reduceMotion
            )
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
