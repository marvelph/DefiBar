import AppKit

private let activeWorkspaceBorderColor = NSColor.systemBlue.withAlphaComponent(0.65)
private let workspaceButtonHeight: CGFloat = 22
private let iconSize: CGFloat = 14
private let iconSlotWidth: CGFloat = 18

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
        titleRequest?.cancel()
        titleRequest = nil
        updateTooltip(title: nil)
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
final class WorkspaceButton: NSButton {
    let display: Int
    let position: Int
    let isActive: Bool
    private var windowSlots: [WindowIconSlot] = []

    func windowID(at pointInWindow: NSPoint) -> UInt64? {
        windowSlots.first { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }?.windowID
    }

    func showWindowClickFeedback(id: UInt64, startedAt: CFTimeInterval) {
        windowSlots.first { $0.windowID == id }?.showClickFeedback(startedAt: startedAt)
    }

    init(
        workspace: WorkspaceState.Workspace,
        display: Int,
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

        let label = NSTextField(labelWithString: workspace.label)
        label.font = .systemFont(ofSize: 12, weight: workspace.active ? .semibold : .medium)
        let labelView: NSView
        let labelWidth: CGFloat
        let labelSymbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: workspace.active ? .semibold : .medium
        )
        if workspace.kind == "trailing",
           let image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(labelSymbolConfiguration) {
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            labelWidth = ceil(image.size.width)
            view.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            labelView = view
        } else {
            labelView = label
            labelWidth = ceil(label.intrinsicContentSize.width)
        }
        let horizontalInset: CGFloat = 6
        let labelSpacing: CGFloat = 2
        let (iconViews, iconWidth) = makeIconViews(for: workspace, icon: icon)

        let content = NSStackView(views: [labelView] + iconViews)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 0
        content.setCustomSpacing(labelSpacing, after: labelView)
        var workspaceLabelWidth = labelWidth
        if let image = workspace.symbolImage {
            let view = NSImageView(image: image)
            let spacing: CGFloat = 4
            view.imageScaling = .scaleProportionallyUpOrDown
            view.contentTintColor = .labelColor
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: iconSize),
                view.heightAnchor.constraint(equalToConstant: iconSize)
            ])
            content.insertArrangedSubview(view, at: 0)
            content.setCustomSpacing(spacing, after: view)
            workspaceLabelWidth += iconSize + spacing
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

        if !workspace.active {
            let windowCount = String.localizedStringWithFormat(localized("workspace.windowCount"), workspace.windowCount)
            toolTip = "\(workspace.label) · \(windowCount)"
        }
        setAccessibilityLabel(workspace.label)
        if let bundleID = workspace.focusedApplication, workspace.active, !iconViews.isEmpty {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
                ?? bundleID
            setAccessibilityValue(String(format: localized("workspace.selectedApp"), name))
        }
        setAccessibilityHelp(workspace.active ? localized("workspace.active") : localized("workspace.switch"))
    }

    private func makeIconViews(
        for workspace: WorkspaceState.Workspace,
        icon: (String) -> NSImage
    ) -> (views: [NSView], width: CGFloat) {
        guard workspace.active else { return ([], 0) }

        var iconViews: [NSView] = []
        var iconWidth: CGFloat = 0
        func appendWindow(_ window: WorkspaceState.Window) {
            let slot = WindowIconSlot(window: window, image: icon(window.appID))
            windowSlots.append(slot)
            iconViews.append(slot)
            iconWidth += iconSlotWidth
        }

        let markerPointSize: CGFloat = 12
        let markerOpacity: CGFloat = 0.65

        func appendWindowGroupMarker(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: markerPointSize, weight: .medium)
            label.alphaValue = markerOpacity
            label.alignment = .center
            label.setAccessibilityElement(false)
            let width = ceil(label.intrinsicContentSize.width)
            let marker = NSView()
            marker.addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                marker.widthAnchor.constraint(equalToConstant: width),
                marker.heightAnchor.constraint(equalToConstant: workspaceButtonHeight),
                label.leadingAnchor.constraint(equalTo: marker.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: marker.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: marker.centerYAnchor)
            ])
            iconViews.append(marker)
            iconWidth += width
        }

        func appendWindowGroupSymbol(_ name: String, fallback: String) {
            let configuration = NSImage.SymbolConfiguration(pointSize: markerPointSize, weight: .medium)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else {
                appendWindowGroupMarker(fallback)
                return
            }
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            view.alphaValue = markerOpacity
            view.setAccessibilityElement(false)
            let width = ceil(image.size.width)
            view.widthAnchor.constraint(equalToConstant: width).isActive = true
            iconViews.append(view)
            iconWidth += width
        }

        var markedFullscreen = false
        for column in workspace.tiledColumns {
            if !markedFullscreen, column.first?.nativeFullscreen == true {
                appendWindowGroupSymbol("arrow.up.left.and.arrow.down.right", fallback: "⤢")
                markedFullscreen = true
            }
            let stacked = column.count > 1
            if stacked { appendWindowGroupMarker("[") }
            for window in column {
                appendWindow(window)
            }
            if stacked { appendWindowGroupMarker("]") }
        }
        let floating = workspace.windows.filter(\.floating)
        if !floating.isEmpty {
            appendWindowGroupSymbol("macwindow.on.rectangle", fallback: "❐")
        }
        for window in floating {
            appendWindow(window)
        }
        return (iconViews, iconWidth)
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
