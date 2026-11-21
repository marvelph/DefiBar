import AppKit

private let iconSlotWidth: CGFloat = 18

enum WindowStripScrollGesture {
    case idle, waitingForHorizontalMovement, scrolling

    mutating func shouldScroll(
        phase: NSEvent.Phase, momentum: NSEvent.Phase, isOverStrip: Bool,
        hasHorizontalMovement: Bool, hasPreciseDeltas: Bool
    ) -> Bool {
        if phase.contains(.cancelled) || momentum.contains(.cancelled) {
            self = .idle
            return false
        }

        if !momentum.isEmpty {
            let shouldScroll = self == .scrolling && hasHorizontalMovement
            if momentum.contains(.ended) { self = .idle }
            return shouldScroll
        }

        if phase.isEmpty {
            let shouldScroll = isOverStrip && hasHorizontalMovement
            self = shouldScroll && hasPreciseDeltas ? .scrolling : .idle
            return shouldScroll
        }

        if phase.contains(.mayBegin) || phase.contains(.began) {
            self = isOverStrip ? .waitingForHorizontalMovement : .idle
        }
        if self != .idle && hasHorizontalMovement {
            self = .scrolling
            return true
        }
        if phase.contains(.ended), self == .waitingForHorizontalMovement { self = .idle }
        return false
    }
}

@MainActor
private final class WindowIconSlot: NSView {
    let windowID: UInt64
    private let showsFocus: Bool
    private let appName: String
    private var hoverArea: NSTrackingArea?
    private var titleRequest: Task<Void, Never>?

    init(window: WorkspaceState.Window, image: NSImage) {
        windowID = window.id
        showsFocus = window.selected
        appName = NSRunningApplication.runningApplications(withBundleIdentifier: window.appID).first?.localizedName
            ?? window.appID
        super.init(frame: .zero)

        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: iconSlotWidth),
            heightAnchor.constraint(equalToConstant: workspaceButtonHeight),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: statusIconSize),
            icon.heightAnchor.constraint(equalToConstant: statusIconSize)
        ])
        toolTip = appName
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        titleRequest?.cancel()
        titleRequest = Task { [weak self, windowID] in
            let title = await Task.detached(priority: .utility) {
                try? DefiClient.windowTitle(for: windowID)
            }.value
            guard !Task.isCancelled, let self, self.window != nil else { return }
            updateTooltip(title: title)
        }
    }

    override func mouseExited(with event: NSEvent) {
        // AppKit may still be displaying the tooltip while it dismisses it.
        titleRequest?.cancel()
        titleRequest = nil
    }

    private func updateTooltip(title: String?) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = title.isEmpty ? appName : "\(appName) · \(title)"
        if toolTip != text { toolTip = text }
    }

    func showClickFeedback(startedAt: CFTimeInterval) {
        wantsLayer = true
        guard let layer else { return }
        layer.cornerRadius = 4
        effectiveAppearance.performAsCurrentDrawingAppearance {
            animateClickFeedback(
                on: layer, color: activeWorkspaceBorderColor.cgColor,
                background: NSColor.clear.cgColor, startedAt: startedAt
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsFocus else { return }

        let bump = NSBezierPath()
        bump.appendArc(
            withCenter: NSPoint(x: bounds.midX, y: bounds.minY + 1),
            radius: 2,
            startAngle: 0,
            endAngle: 180
        )
        bump.close()
        activeWorkspaceBorderColor.setFill()
        bump.fill()
    }
}

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
            workspace: workspace, slotWidth: iconSlotWidth, markerWidths: Self.markerWidths
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
        placeMarker(leftMarker, x: 0, width: edges.left)
        placeMarker(rightMarker, x: stripWidth - edges.right, width: edges.right)
        updateVisibleViews()
    }

    private func placeMarker(_ marker: NSView, x: CGFloat, width: CGFloat) {
        marker.isHidden = width == 0
        if width > 0 {
            let height = marker.intrinsicContentSize.height
            marker.frame = NSRect(x: x, y: (workspaceButtonHeight - height) / 2, width: width, height: height)
        }
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
            let height: CGFloat
            switch element.item {
            case .window(let window):
                view = WindowIconSlot(window: window, image: icon(window.appID))
                height = workspaceButtonHeight
            case .marker(let marker):
                guard let marker = Self.markers[marker] else { continue }
                view = marker.makeView()
                height = view.intrinsicContentSize.height
            }
            view.frame = NSRect(x: element.x, y: (workspaceButtonHeight - height) / 2,
                                width: element.width, height: height)
            document.addSubview(view)
            visibleViews[index] = view
        }
    }
}

@MainActor
private struct WindowMarker {
    private let text: String
    private let image: NSImage?
    private let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    let width: CGFloat

    init(_ marker: WindowStripLayout.Marker) {
        let symbol: String?
        switch marker {
        case .fullscreen: (symbol, text) = ("arrow.up.left.and.arrow.down.right", "⤢")
        case .stackStart: (symbol, text) = (nil, "[")
        case .stackEnd: (symbol, text) = (nil, "]")
        case .floating: (symbol, text) = ("macwindow.on.rectangle", "❐")
        case .continuationLeft: (symbol, text) = ("chevron.left", "‹")
        case .continuationRight: (symbol, text) = ("chevron.right", "›")
        }
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        if let image {
            width = ceil(image.size.width)
        } else {
            width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    func makeView() -> NSView {
        let view: NSView
        if let image {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            view = icon
        } else {
            view = WindowMarkerText(text: text, font: font)
        }
        view.alphaValue = 0.65
        view.setAccessibilityElement(false)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}

@MainActor
private final class WindowMarkerText: NSView {
    private let text: NSString
    private let font: NSFont
    private let textSize: NSSize

    init(text: String, font: NSFont) {
        self.text = text as NSString
        self.font = font
        textSize = (text as NSString).size(withAttributes: [.font: font])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textSize.width), height: ceil(textSize.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let origin = NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2)
        text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}
