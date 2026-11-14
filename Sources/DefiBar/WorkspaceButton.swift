import AppKit

private let activeWorkspaceBorderColor = NSColor.systemBlue.withAlphaComponent(0.65)
private var windowGroupMarkerColor: NSColor { NSColor.labelColor.withAlphaComponent(0.35) }
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
private final class AppIconSlot: NSView {
    var showsFocus = false
    var windowID: UInt64?
    private var hoverArea: NSTrackingArea?
    private var titleRequest: Task<Void, Never>?
    private var appName: String?

    func configureTooltip(appName: String) {
        self.appName = appName
        updateTooltip(title: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        guard windowID != nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard let windowID else { return }
        titleRequest?.cancel()
        titleRequest = Task { [weak self] in
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
        guard let appName else { return }
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
    private var windowSlots: [AppIconSlot] = []

    func windowID(at pointInWindow: NSPoint) -> UInt64? {
        windowSlots.first { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }?.windowID
    }

    func showWindowClickFeedback(id: UInt64, startedAt: CFTimeInterval) {
        windowSlots.first { $0.windowID == id }?.showClickFeedback(startedAt: startedAt)
    }

    init(
        workspace: WorkspaceState.Workspace,
        display: Int,
        showsWindowDetails: Bool,
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
        let horizontalInset: CGFloat = 6
        let labelSpacing: CGFloat = 2
        let (iconViews, iconWidth) = makeIconViews(
            for: workspace, showsWindowDetails: showsWindowDetails, icon: icon
        )

        let content = NSStackView(views: [label] + iconViews)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 0
        content.setCustomSpacing(labelSpacing, after: label)
        var workspaceLabelWidth = ceil(label.intrinsicContentSize.width)
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

        let windowCount = String.localizedStringWithFormat(localized("workspace.windowCount"), workspace.windowCount)
        toolTip = "\(workspace.label) · \(windowCount)"
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
        showsWindowDetails: Bool,
        icon: (String) -> NSImage
    ) -> (views: [NSView], width: CGFloat) {
        guard workspace.active else { return ([], 0) }

        func makeSlot(appID: String, window: WorkspaceState.Window? = nil) -> AppIconSlot {
            let view = NSImageView(image: icon(appID))
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            let slot = AppIconSlot(frame: .zero)
            slot.showsFocus = window?.selected ?? (appID == workspace.focusedApplication)
            slot.windowID = window?.id
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: iconSlotWidth),
                slot.heightAnchor.constraint(equalToConstant: workspaceButtonHeight),
                view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: iconSize),
                view.heightAnchor.constraint(equalToConstant: iconSize)
            ])
            if window != nil {
                let appName = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
                    ?? appID
                slot.configureTooltip(appName: appName)
                windowSlots.append(slot)
            }
            return slot
        }

        var iconViews: [NSView] = []
        var iconWidth: CGFloat = 0
        func appendSlot(_ slot: AppIconSlot) {
            iconViews.append(slot)
            iconWidth += iconSlotWidth
        }

        func appendWindowGroupMarker(_ text: String) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = windowGroupMarkerColor
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
                label.centerYAnchor.constraint(equalTo: marker.centerYAnchor, constant: -1)
            ])
            iconViews.append(marker)
            iconWidth += width
        }

        if showsWindowDetails {
            for column in workspace.tiledColumns {
                let stacked = column.count > 1
                if stacked { appendWindowGroupMarker("(") }
                for window in column {
                    appendSlot(makeSlot(appID: window.appID, window: window))
                }
                if stacked { appendWindowGroupMarker(")") }
            }
            let floating = workspace.windows.filter(\.floating)
            if !floating.isEmpty, !iconViews.isEmpty {
                appendWindowGroupMarker("|")
            }
            for window in floating {
                appendSlot(makeSlot(appID: window.appID, window: window))
            }
        } else {
            var seen = Set<String>()
            for appID in workspace.applications where seen.insert(appID).inserted {
                appendSlot(makeSlot(appID: appID))
            }
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
