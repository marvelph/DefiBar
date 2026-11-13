import AppKit
import SwiftUI

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

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let background = NSHostingView(rootView: WorkspaceHUDSurface())
        background.sizingOptions = []
        background.frame = root.bounds
        background.autoresizingMask = [.width, .height]
        root.addSubview(background)
        root.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: min(contentWidth, width - 24)),
            content.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])

        panel.contentView = root
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

private struct WorkspaceHUDSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Match the surface used by Defi's recent windows switcher.
        let color: Color = colorScheme == .dark ? .black : .white
        let shape = RoundedRectangle(cornerRadius: 20)
        let surface = Color.clear
            .background(
                LinearGradient(
                    stops: [
                        .init(color: color.opacity(0.94), location: 0),
                        .init(color: color.opacity(0.94), location: 0.4),
                        .init(color: color.opacity(0), location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                ),
                in: shape
            )

        if #available(macOS 26, *) {
            surface.glassEffect(.regular, in: shape)
        } else {
            surface.background(.regularMaterial, in: shape)
        }
    }
}
