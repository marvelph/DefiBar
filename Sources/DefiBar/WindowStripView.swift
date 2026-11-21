import AppKit

private let iconSlotWidth: CGFloat = 18

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
final class WindowStripView: NSStackView {
    enum ScrollDirection: Int {
        case left, right
    }

    private static let maximumWidth: CGFloat = 144
    private static let arrowWidth: CGFloat = 12
    private static let markers = Dictionary(uniqueKeysWithValues: WindowStripLayout.Marker.allCases.map {
        ($0, WindowMarker($0))
    })

    private let visibleStrip: WindowStripLayout.VisibleStrip
    private var windowSlots: [WindowIconSlot] = []
    private var arrows: [ScrollDirection: NSButton] = [:]
    var onScroll: ((ScrollDirection, UInt64) -> Void)?

    var viewport: WindowStripViewport? { visibleStrip.viewport }
    var stripWidth: CGFloat { viewport == nil ? visibleStrip.width : Self.maximumWidth }

    init(workspace: WorkspaceState.Workspace, viewport: WindowStripViewport?, icon: (String) -> NSImage) {
        let layout = WindowStripLayout(
            workspace: workspace, slotWidth: iconSlotWidth, markerWidths: Self.markers.mapValues(\.width)
        )
        visibleStrip = layout.visibleStrip(maximumWidth: Self.maximumWidth, arrowWidth: Self.arrowWidth, viewport: viewport)
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        for item in visibleStrip.items {
            switch item {
            case .marker(let marker):
                if let style = Self.markers[marker] { addArrangedSubview(style.makeView()) }
            case .window(let window):
                let slot = WindowIconSlot(window: window, image: icon(window.appID))
                windowSlots.append(slot)
                addArrangedSubview(slot)
            }
        }
        if visibleStrip.viewport != nil { addScrollControls() }
        widthAnchor.constraint(equalToConstant: stripWidth).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func windowID(at pointInWindow: NSPoint) -> UInt64? {
        windowSlots.first { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }?.windowID
    }

    func handleScroll(at pointInWindow: NSPoint) -> Bool {
        guard let arrow = arrows.values.first(where: {
            $0.bounds.contains($0.convert(pointInWindow, from: nil))
        }) else { return false }
        if arrow.isEnabled { arrow.performClick(nil) }
        return true
    }

    func showWindowClickFeedback(id: UInt64, startedAt: CFTimeInterval) {
        windowSlots.first { $0.windowID == id }?.showClickFeedback(startedAt: startedAt)
    }

    func showScrollClickFeedback(_ direction: ScrollDirection, startedAt: CFTimeInterval) {
        guard let arrow = arrows[direction] else { return }
        arrow.wantsLayer = true
        guard let layer = arrow.layer else { return }
        layer.cornerRadius = 4
        arrow.effectiveAppearance.performAsCurrentDrawingAppearance {
            animateClickFeedback(
                on: layer, color: activeWorkspaceBorderColor.cgColor,
                background: NSColor.clear.cgColor, startedAt: startedAt
            )
        }
    }

    private func addScrollControls() {
        let left = makeArrow(.left)
        let right = makeArrow(.right)
        arrows = [.left: left, .right: right]
        insertArrangedSubview(left, at: 0)

        let remainingWidth = Self.maximumWidth - 2 * Self.arrowWidth - visibleStrip.width
        if remainingWidth > 0 {
            // Keep the right arrow in place while the amount of visible content changes.
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: remainingWidth).isActive = true
            addArrangedSubview(spacer)
        }
        addArrangedSubview(right)
    }

    private func destination(for direction: ScrollDirection) -> UInt64? {
        direction == .left ? visibleStrip.previousWindowID : visibleStrip.nextWindowID
    }

    private func makeArrow(_ direction: ScrollDirection) -> NSButton {
        let goesLeft = direction == .left
        let symbol = goesLeft ? "chevron.left" : "chevron.right"
        let help = localized(goesLeft ? "workspace.scrollWindowsLeft" : "workspace.scrollWindowsRight")
        let button = NSButton(frame: .zero)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = goesLeft ? "‹" : "›"
        }
        button.isBordered = false
        button.isEnabled = destination(for: direction) != nil
        button.tag = direction.rawValue
        button.target = self
        button.action = #selector(scrollArrowClicked(_:))
        button.toolTip = help
        button.setAccessibilityLabel(help)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.arrowWidth),
            button.heightAnchor.constraint(equalToConstant: workspaceButtonHeight)
        ])
        return button
    }

    @objc private func scrollArrowClicked(_ sender: NSButton) {
        guard let direction = ScrollDirection(rawValue: sender.tag), let windowID = destination(for: direction) else {
            return
        }
        onScroll?(direction, windowID)
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
        }
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        if let image {
            width = ceil(image.size.width)
        } else {
            let label = NSTextField(labelWithString: text)
            label.font = font
            width = ceil(label.intrinsicContentSize.width)
        }
    }

    func makeView() -> NSView {
        let view: NSView
        if let image {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            view = icon
        } else {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.alignment = .center
            view = label
        }
        view.alphaValue = 0.65
        view.setAccessibilityElement(false)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}
