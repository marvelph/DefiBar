import AppKit

@MainActor
final class WorkspaceHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(_ title: String, icon: NSImage?, on screen: NSScreen) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let content: NSView
        if let icon {
            let stack = NSStackView(views: [label])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 9
            let imageView = NSImageView(image: icon)
            let size: CGFloat = 22
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = .labelColor
            stack.insertArrangedSubview(imageView, at: 0)
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: size),
                imageView.heightAnchor.constraint(equalToConstant: size)
            ])
            content = stack
        } else {
            content = label
        }

        let visibleFrame = screen.visibleFrame
        let contentWidth = ceil(content.fittingSize.width)
        let width = min(max(contentWidth + 48, 76), visibleFrame.width - 16)
        let height: CGFloat = 64
        let frame = NSRect(x: visibleFrame.midX - width / 2, y: visibleFrame.midY - height / 2,
                           width: width, height: height)

        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        let cornerRadius: CGFloat = 18
        // Mask the behind-window material itself, including the blur at the corners.
        background.maskImage = NSImage(size: frame.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        let outline = NSView(frame: background.bounds)
        outline.wantsLayer = true
        outline.layer?.cornerRadius = cornerRadius
        outline.layer?.borderWidth = 1 / screen.backingScaleFactor
        outline.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        background.addSubview(outline)
        background.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: min(contentWidth, width - 24)),
            content.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor)
        ])

        panel.contentView = background
        self.panel = panel
        panel.orderFrontRegardless()

        dismissTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
            self?.panel = nil
        }
    }
}
