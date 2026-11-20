import AppKit
import SwiftUI

@MainActor
final class WorkspaceHUD {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(
        _ workspace: WorkspaceState.Workspace,
        showsWorkspaceName: Bool,
        showsWorkspaceNumberSign: Bool,
        showsTrailingWorkspaceIcon: Bool,
        showsApplications: Bool,
        appIcon: (String) -> NSImage,
        on screen: NSScreen
    ) {
        dismiss()

        let label = NSTextField(labelWithString: workspace.label(
            showingName: showsWorkspaceName,
            showingNumberSign: showsWorkspaceNumberSign,
            showingTrailingIcon: showsTrailingWorkspaceIcon
        ))
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
        let horizontalPadding: CGFloat = 24
        let content = NSStackView(views: [heading])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 8

        let appIconSize: CGFloat = 64
        let iconInset: CGFloat = 6
        let iconTileSize = appIconSize + 2 * iconInset
        let iconSpacing: CGFloat = 2
        let rowInset: CGFloat = 4
        let iconStride = iconTileSize + iconSpacing
        let maximumRowWidth = maximumWidth - 2 * horizontalPadding
        let iconsPerRow = max(1, Int((maximumRowWidth - 2 * rowInset + iconSpacing) / iconStride))
        let applications = showsApplications ? workspace.applications : []
        for start in stride(from: 0, to: applications.count, by: iconsPerRow) {
            let end = min(start + iconsPerRow, applications.count)
            let icons = applications[start..<end].map { appID in
                let selected = appID == workspace.focusedApplication
                let view = NSHostingView(rootView:
                    Image(nsImage: appIcon(appID))
                        .resizable()
                        .scaledToFit()
                        .frame(width: appIconSize, height: appIconSize)
                        .padding(iconInset)
                        .background(
                            selected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 12)
                        )
                )
                view.sizingOptions = []
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: iconTileSize),
                    view.heightAnchor.constraint(equalToConstant: iconTileSize)
                ])
                return view
            }
            let row = NSStackView(views: icons)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = iconSpacing
            row.edgeInsets = NSEdgeInsets(top: rowInset, left: rowInset, bottom: rowInset, right: rowInset)
            content.addArrangedSubview(row)
            let rowWidth = CGFloat(icons.count) * iconStride - iconSpacing + 2 * rowInset
            row.widthAnchor.constraint(equalToConstant: rowWidth).isActive = true
        }

        let contentSize = content.fittingSize
        let contentWidth = ceil(contentSize.width)
        let width = min(max(contentWidth + 2 * horizontalPadding, 76), maximumWidth)
        let height = max(64, ceil(contentSize.height) + 32)
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
            content.widthAnchor.constraint(equalToConstant: min(contentWidth, width - horizontalPadding)),
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

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
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
