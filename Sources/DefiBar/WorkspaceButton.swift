import AppKit

let activeWorkspaceBorderColor = NSColor.systemBlue.withAlphaComponent(0.65)
let workspaceButtonHeight: CGFloat = 22
let statusIconSize: CGFloat = 14

let clickFeedbackDuration = 0.40

func animateClickFeedback(
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
final class WorkspaceButton: NSButton {
    let display: Int
    let position: Int
    let isActive: Bool
    private(set) var windowStrip: WindowStripView?

    init(
        workspace: WorkspaceState.Workspace,
        display: Int,
        labelStyle: WorkspaceState.Workspace.LabelStyle,
        showsWorkspaceIcon: Bool,
        hidesLabelWithIcon: Bool,
        showsActiveWorkspaceWindows: Bool,
        windowStripMaximumWidth: CGFloat,
        windowStripPosition: WindowStripPosition?,
        icon: @escaping (String) -> NSImage
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
        let labelPointSize: CGFloat = 12
        let labelWeight: NSFont.Weight = isActive ? .semibold : .medium
        let labelView: NSView?
        let labelWidth: CGFloat
        if hidesLabel {
            labelWidth = 0
            labelView = nil
        } else if let image = workspace.trailingPlusImage(
            style: labelStyle, pointSize: labelPointSize, weight: labelWeight
        ) {
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            labelWidth = ceil(image.size.width)
            view.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
            labelView = view
        } else {
            let label = NSTextField(labelWithString: labelText)
            label.font = .systemFont(ofSize: labelPointSize, weight: labelWeight)
            labelView = label
            labelWidth = ceil(label.intrinsicContentSize.width)
        }
        let horizontalInset: CGFloat = 6
        let labelSpacing: CGFloat = 2
        if isActive, showsActiveWorkspaceWindows, !workspace.windows.isEmpty {
            windowStrip = WindowStripView(
                workspace: workspace, maximumWidth: windowStripMaximumWidth, position: windowStripPosition, icon: icon
            )
        }

        let content = NSStackView(views: [labelView, windowStrip].compactMap { $0 })
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
                view.widthAnchor.constraint(equalToConstant: statusIconSize),
                view.heightAnchor.constraint(equalToConstant: statusIconSize)
            ])
            content.insertArrangedSubview(view, at: 0)
            workspaceLabelWidth += statusIconSize
            if hidesLabel {
                content.setCustomSpacing(labelSpacing, after: view)
                if windowStrip != nil { view.toolTip = labelText }
            } else {
                let iconSpacing: CGFloat = 4
                content.setCustomSpacing(iconSpacing, after: view)
                workspaceLabelWidth += iconSpacing
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        // Keep the frame tied to its contents when the status bar lays out the row again.
        let stripWidth = windowStrip.map { $0.stripWidth + labelSpacing } ?? 0
        let buttonWidth = workspaceLabelWidth + stripWidth + 2 * horizontalInset
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: buttonWidth),
            heightAnchor.constraint(equalToConstant: workspaceButtonHeight)
        ])

        if windowStrip == nil {
            let windowCount = String.localizedStringWithFormat(localized("workspace.windowCount"), workspace.windowCount)
            toolTip = "\(labelText) · \(windowCount)"
        }
        setAccessibilityLabel(labelText)
        if let bundleID = workspace.focusedApplication, windowStrip != nil {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
                ?? bundleID
            setAccessibilityValue(String(format: localized("workspace.selectedApp"), name))
        }
        setAccessibilityHelp(workspace.active ? localized("workspace.active") : localized("workspace.switch"))
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
