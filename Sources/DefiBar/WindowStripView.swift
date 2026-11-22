import AppKit

@MainActor
final class WindowStripView: NSView {
    private static let markers = Dictionary(uniqueKeysWithValues: WindowStripLayout.Marker.allCases.map {
        ($0, WindowMarker($0))
    })
    private static let markerWidths = markers.mapValues(\.width)

    let stripWidth: CGFloat
    var canScroll: Bool { stripLayout.maximumOffset(for: stripWidth) > 0 }
    var position: WindowStripPosition {
        WindowStripPosition(offset: offset, focusedWindowID: stripLayout.focusedWindowID, focusAnimation: focusAnimation)
    }

    private let stripLayout: WindowStripLayout
    private let icon: (String) -> NSImage
    private let clip = NSClipView()
    private let document: NSView
    private let leftMarker: NSView
    private let rightMarker: NSView
    private var offset: CGFloat
    private var focusAnimation: WindowStripFocusAnimation?
    private var focusAnimationTimer: Timer?
    private var visibleViews: [Int: NSView] = [:]

    init(
        workspace: WorkspaceState.Workspace, maximumWidth: CGFloat, position: WindowStripPosition?,
        icon: @escaping (String) -> NSImage
    ) {
        let layout = WindowStripLayout(
            workspace: workspace, slotWidth: WindowIconSlot.slotWidth, markerWidths: Self.markerWidths
        )
        stripLayout = layout
        let viewportWidth = min(maximumWidth, layout.contentWidth)
        stripWidth = viewportWidth
        self.icon = icon
        let restored = layout.restoredPosition(
            for: viewportWidth, previous: position,
            animatesFocus: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, at: CACurrentMediaTime()
        )
        offset = restored.offset
        focusAnimation = restored.focusAnimation
        document = NSView(frame: NSRect(x: 0, y: 0, width: layout.contentWidth, height: workspaceButtonHeight))
        leftMarker = Self.markers[.continuationLeft]!.makeView()
        rightMarker = Self.markers[.continuationRight]!.makeView()
        super.init(frame: NSRect(x: 0, y: 0, width: stripWidth, height: workspaceButtonHeight))

        clipsToBounds = true
        clip.drawsBackground = false
        clip.clipsToBounds = true
        clip.documentView = document
        addSubview(clip)
        addSubview(leftMarker)
        addSubview(rightMarker)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: stripWidth),
            heightAnchor.constraint(equalToConstant: workspaceButtonHeight)
        ])
        updateViewport()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopFocusAnimationTimer()
        guard window != nil, focusAnimation != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFocusAnimation(at: CACurrentMediaTime()) }
        }
        focusAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func contains(_ pointInWindow: NSPoint) -> Bool {
        bounds.contains(convert(pointInWindow, from: nil))
    }

    func scrollHorizontally(by delta: CGFloat) -> Bool {
        guard canScroll else { return false }
        focusAnimation = nil
        stopFocusAnimationTimer()
        setOffset(stripLayout.clampedOffset(offset + delta, viewportWidth: stripWidth))
        return true
    }

    func windowID(at pointInWindow: NSPoint) -> UInt64? {
        guard clip.frame.contains(convert(pointInWindow, from: nil)) else { return nil }
        return visibleViews.values.compactMap { $0 as? WindowIconSlot }
            .first { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }?.windowID
    }

    func containsContinuationMarker(at pointInWindow: NSPoint) -> Bool {
        let point = convert(pointInWindow, from: nil)
        return bounds.contains(point) && !clip.frame.contains(point)
    }

    func showWindowClickFeedback(id: UInt64, startedAt: CFTimeInterval) {
        visibleViews.values.compactMap { $0 as? WindowIconSlot }
            .first { $0.windowID == id }?.showClickFeedback(startedAt: startedAt)
    }

    private func advanceFocusAnimation(at time: TimeInterval) {
        guard let focusAnimation else { return }
        setOffset(focusAnimation.offset(at: time))
        if time >= focusAnimation.endsAt {
            self.focusAnimation = nil
            stopFocusAnimationTimer()
        }
    }

    private func stopFocusAnimationTimer() {
        focusAnimationTimer?.invalidate()
        focusAnimationTimer = nil
    }

    private func setOffset(_ newOffset: CGFloat) {
        guard newOffset != offset else { return }
        offset = newOffset
        updateViewport()
    }

    private func updateViewport() {
        let edges = stripLayout.edges(at: offset, viewportWidth: stripWidth)
        clip.frame = NSRect(x: edges.left, y: 0, width: stripWidth - edges.left - edges.right,
                            height: workspaceButtonHeight)
        // Compensate for the marker's inset so the document moves only by the scroll offset.
        clip.scroll(to: NSPoint(x: offset + edges.left, y: 0))
        placeMarker(leftMarker, inset: edges.left, onLeft: true)
        placeMarker(rightMarker, inset: edges.right, onLeft: false)
        updateVisibleViews()
    }

    private func placeMarker(_ marker: NSView, inset: CGFloat, onLeft: Bool) {
        marker.isHidden = inset == 0
        guard inset > 0 else { return }

        let x = onLeft ? inset - marker.frame.width : stripWidth - inset
        marker.setFrameOrigin(NSPoint(x: x, y: 0))
    }

    private func updateVisibleViews() {
        let visibleBounds = clip.bounds
        let elements = stripLayout.elements
        let visible = elements.indices.filter {
            elements[$0].x < visibleBounds.maxX && elements[$0].x + elements[$0].width > visibleBounds.minX
        }
        let visibleIndices = Set(visible)
        for index in visibleViews.keys.filter({ !visibleIndices.contains($0) }) {
            visibleViews.removeValue(forKey: index)?.removeFromSuperview()
        }
        for index in visible where visibleViews[index] == nil {
            let element = elements[index]
            let view: NSView
            switch element.item {
            case .window(let window):
                view = WindowIconSlot(window: window, image: icon(window.appID))
            case .marker(let marker):
                guard let marker = Self.markers[marker] else { continue }
                view = marker.makeView()
            }
            view.frame = NSRect(x: element.x, y: 0, width: element.width, height: workspaceButtonHeight)
            document.addSubview(view)
            visibleViews[index] = view
        }
    }
}
