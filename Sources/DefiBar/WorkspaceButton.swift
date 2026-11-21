import AppKit

private let activeWorkspaceBorderColor = NSColor.systemBlue.withAlphaComponent(0.65)
private let workspaceButtonHeight: CGFloat = 22
private let iconSize: CGFloat = 14
private let iconSlotWidth: CGFloat = 18
private let windowStripMaximumWidth: CGFloat = 144
private let windowScrollButtonWidth: CGFloat = 12

let clickFeedbackDuration = 0.40

private func animateClickFeedback(
    on layer: CALayer, color: CGColor, background: CGColor, startedAt: CFTimeInterval
) {
    guard CACurrentMediaTime() - startedAt < clickFeedbackDuration else { return }
    let feedback = CAKeyframeAnimation(keyPath: "backgroundColor")
    feedback.values = [color, color, background]
    feedback.keyTimes = [0, 0.20, 1]
    feedback.beginTime = layer.convertTime(startedAt, from: nil)
    feedback.duration = clickFeedbackDuration
    layer.add(feedback, forKey: "clickFeedback")
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
            icon.widthAnchor.constraint(equalToConstant: iconSize),
            icon.heightAnchor.constraint(equalToConstant: iconSize)
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

@MainActor
final class WorkspaceButton: NSButton {
    enum ScrollDirection {
        case left, right
    }

    let display: Int
    let position: Int
    let isActive: Bool
    private(set) var windowStripViewport: WindowStripViewport?
    var onWindowScroll: ((ScrollDirection, UInt64) -> Void)?
    private var windowSlots: [WindowIconSlot] = []
    private var windowScrollButtons: [ScrollDirection: NSButton] = [:]
    private var previousWindowID: UInt64?
    private var nextWindowID: UInt64?

    func windowID(at pointInWindow: NSPoint) -> UInt64? {
        windowSlots.first { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }?.windowID
    }

    func showWindowClickFeedback(id: UInt64, startedAt: CFTimeInterval) {
        windowSlots.first { $0.windowID == id }?.showClickFeedback(startedAt: startedAt)
    }

    func handleWindowScroll(at pointInWindow: NSPoint) -> Bool {
        guard let button = windowScrollButtons.values.first(where: {
            $0.bounds.contains($0.convert(pointInWindow, from: nil))
        }) else { return false }
        if button.isEnabled { button.performClick(nil) }
        return true
    }

    func showScrollClickFeedback(_ direction: ScrollDirection, startedAt: CFTimeInterval) {
        guard let button = windowScrollButtons[direction] else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        layer.cornerRadius = 4
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            animateClickFeedback(
                on: layer, color: activeWorkspaceBorderColor.cgColor,
                background: NSColor.clear.cgColor, startedAt: startedAt
            )
        }
    }

    init(
        workspace: WorkspaceState.Workspace,
        display: Int,
        labelStyle: WorkspaceState.Workspace.LabelStyle,
        showsWorkspaceIcon: Bool,
        hidesLabelWithIcon: Bool,
        showsActiveWorkspaceWindows: Bool,
        windowStripViewport: WindowStripViewport?,
        icon: (String) -> NSImage
    ) {
        self.display = display
        position = workspace.position
        isActive = workspace.active
        super.init(frame: .zero)

        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        updateSurfaceColors()

        let labelText = workspace.label(style: labelStyle)
        let workspaceIcon = showsWorkspaceIcon ? workspace.symbolImage : nil
        let hidesLabel = hidesLabelWithIcon && workspaceIcon != nil
        let labelWeight: NSFont.Weight = isActive ? .semibold : .medium
        let labelView: NSView?
        let labelWidth: CGFloat
        let labelSymbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: labelWeight
        )
        if hidesLabel {
            labelWidth = 0
            labelView = nil
        } else if labelStyle.showsTrailingPlus, workspace.kind == "trailing",
                  let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(labelSymbolConfiguration) {
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            labelWidth = ceil(image.size.width)
            view.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            labelView = view
        } else {
            let label = NSTextField(labelWithString: labelText)
            label.font = .systemFont(ofSize: 12, weight: labelWeight)
            labelView = label
            labelWidth = ceil(label.intrinsicContentSize.width)
        }
        let horizontalInset: CGFloat = 6
        let labelSpacing: CGFloat = 2
        let showsWindows = isActive && showsActiveWorkspaceWindows
        let (iconViews, iconWidth) = showsWindows
            ? makeIconViews(for: workspace, viewport: windowStripViewport, icon: icon) : ([], 0)

        let content = NSStackView(views: (labelView.map { [$0] } ?? []) + iconViews)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 0
        if let labelView { content.setCustomSpacing(labelSpacing, after: labelView) }
        var workspaceLabelWidth = labelWidth
        if let image = workspaceIcon {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = .labelColor
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: iconSize),
                view.heightAnchor.constraint(equalToConstant: iconSize)
            ])
            content.insertArrangedSubview(view, at: 0)
            workspaceLabelWidth += iconSize
            if hidesLabel {
                content.setCustomSpacing(labelSpacing, after: view)
                if !iconViews.isEmpty { view.toolTip = labelText }
            } else {
                let iconSpacing: CGFloat = 4
                content.setCustomSpacing(iconSpacing, after: view)
                workspaceLabelWidth += iconSpacing
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Keep the frame tied to its contents when the status bar lays out the row again.
        let buttonWidth = workspaceLabelWidth + iconWidth + (iconViews.isEmpty ? 0 : labelSpacing) + 2 * horizontalInset
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: buttonWidth),
            heightAnchor.constraint(equalToConstant: workspaceButtonHeight)
        ])

        if iconViews.isEmpty {
            let windowCount = String.localizedStringWithFormat(localized("workspace.windowCount"), workspace.windowCount)
            toolTip = "\(labelText) · \(windowCount)"
        }
        setAccessibilityLabel(labelText)
        if let bundleID = workspace.focusedApplication, !iconViews.isEmpty {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
                ?? bundleID
            setAccessibilityValue(String(format: localized("workspace.selectedApp"), name))
        }
        setAccessibilityHelp(workspace.active ? localized("workspace.active") : localized("workspace.switch"))
    }

    private func makeIconViews(
        for workspace: WorkspaceState.Workspace,
        viewport: WindowStripViewport?,
        icon: (String) -> NSImage
    ) -> (views: [NSView], width: CGFloat) {
        guard !workspace.windows.isEmpty else { return ([], 0) }

        let markers = Dictionary(uniqueKeysWithValues: WindowStripLayout.Marker.allCases.map {
            ($0, WindowMarker($0))
        })
        let layout = WindowStripLayout(
            workspace: workspace, slotWidth: iconSlotWidth, markerWidths: markers.mapValues(\.width)
        )
        let strip = layout.visibleStrip(
            maximumWidth: windowStripMaximumWidth, arrowWidth: windowScrollButtonWidth, viewport: viewport
        )
        windowStripViewport = strip.viewport
        var views: [NSView] = []
        for item in strip.items {
            switch item {
            case .marker(let marker):
                if let marker = markers[marker] { views.append(marker.makeView()) }
            case .window(let window):
                let slot = WindowIconSlot(window: window, image: icon(window.appID))
                windowSlots.append(slot)
                views.append(slot)
            }
        }
        guard strip.viewport != nil else { return (views, strip.width) }

        previousWindowID = strip.previousWindowID
        nextWindowID = strip.nextWindowID
        let previous = makeScrollButton(
            symbol: "chevron.left", fallback: "‹", help: localized("workspace.scrollWindowsLeft"),
            action: #selector(scrollWindowsLeft), enabled: previousWindowID != nil
        )
        let next = makeScrollButton(
            symbol: "chevron.right", fallback: "›", help: localized("workspace.scrollWindowsRight"),
            action: #selector(scrollWindowsRight), enabled: nextWindowID != nil
        )
        windowScrollButtons = [.left: previous, .right: next]
        views.insert(previous, at: 0)

        let remainingWidth = windowStripMaximumWidth - 2 * windowScrollButtonWidth - strip.width
        if remainingWidth > 0 {
            // Keep the arrow in the same place as the number of visible markers changes.
            let spacer = NSView()
            spacer.widthAnchor.constraint(equalToConstant: remainingWidth).isActive = true
            views.append(spacer)
        }
        views.append(next)
        return (views, windowStripMaximumWidth)
    }

    private func makeScrollButton(
        symbol: String, fallback: String, help: String, action: Selector, enabled: Bool
    ) -> NSButton {
        let button = NSButton(frame: .zero)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
        }
        button.isBordered = false
        button.isEnabled = enabled
        button.target = self
        button.action = action
        button.toolTip = help
        button.setAccessibilityLabel(help)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: windowScrollButtonWidth),
            button.heightAnchor.constraint(equalToConstant: workspaceButtonHeight)
        ])
        return button
    }

    @objc private func scrollWindowsLeft() {
        if let previousWindowID { onWindowScroll?(.left, previousWindowID) }
    }

    @objc private func scrollWindowsRight() {
        if let nextWindowID { onWindowScroll?(.right, nextWindowID) }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurfaceColors()
    }

    private func updateSurfaceColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ink = NSColor.labelColor
            layer?.borderColor = (isActive ? activeWorkspaceBorderColor : ink.withAlphaComponent(0.18)).cgColor
            layer?.backgroundColor = ink.withAlphaComponent(isActive ? 0.13 : 0.05).cgColor
        }
    }

    func showClickFeedback(startedAt: CFTimeInterval) {
        guard let layer, let borderColor = layer.borderColor,
              let backgroundColor = layer.backgroundColor else { return }
        animateClickFeedback(on: layer, color: borderColor, background: backgroundColor, startedAt: startedAt)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
