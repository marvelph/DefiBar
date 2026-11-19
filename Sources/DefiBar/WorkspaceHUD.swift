import AppKit
import SwiftUI

@MainActor
final class WorkspaceHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(
        _ workspace: WorkspaceState.Workspace, appIcon: (String) -> NSImage, on screen: NSScreen
    ) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: workspace.label)
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        let heading: NSView
        if let icon = workspace.symbolImage {
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
            heading = stack
        } else {
            heading = label
        }

        let visibleFrame = screen.visibleFrame
        let maximumWidth = visibleFrame.width - 16
        let content = NSStackView(views: [heading])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8

        let iconSize: CGFloat = 32
        let iconSpacing: CGFloat = 6
        let iconsPerRow = max(1, Int((maximumWidth - 48 + iconSpacing) / (iconSize + iconSpacing)))
        for start in stride(from: 0, to: workspace.applications.count, by: iconsPerRow) {
            let end = min(start + iconsPerRow, workspace.applications.count)
            let icons = workspace.applications[start..<end].map { appID in
                makeAppIcon(appIcon(appID), size: iconSize, selected: appID == workspace.focusedApplication)
            }
            let row = NSStackView(views: icons)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = iconSpacing
            content.addArrangedSubview(row)
            let rowWidth = CGFloat(icons.count) * iconSize + CGFloat(icons.count - 1) * iconSpacing
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }

        let contentWidth = ceil(content.fittingSize.width)
        let width = min(max(contentWidth + 48, 76), maximumWidth)
        let height = max(64, ceil(content.fittingSize.height) + 32)
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
        root.layoutSubtreeIfNeeded()
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

    private func makeAppIcon(_ image: NSImage, size: CGFloat, selected: Bool) -> NSView {
        let slot = NSView()
        let iconInset: CGFloat = 4
        let dotDiameter: CGFloat = 5
        let dotSpacing: CGFloat = 3
        let icon = NSImageView(image: image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        slot.addSubview(icon)
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: size),
            slot.heightAnchor.constraint(equalToConstant: size - iconInset + dotSpacing + dotDiameter),
            icon.leadingAnchor.constraint(equalTo: slot.leadingAnchor, constant: iconInset),
            icon.trailingAnchor.constraint(equalTo: slot.trailingAnchor, constant: -iconInset),
            icon.topAnchor.constraint(equalTo: slot.topAnchor, constant: iconInset),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor)
        ])
        if selected {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemBlue.cgColor
            dot.layer?.cornerRadius = dotDiameter / 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: dotDiameter),
                dot.heightAnchor.constraint(equalTo: dot.widthAnchor),
                dot.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
                dot.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: dotSpacing)
            ])
        }
        return slot
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
