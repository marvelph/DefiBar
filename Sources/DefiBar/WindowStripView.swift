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
    private static let markers = Dictionary(uniqueKeysWithValues: WindowStripLayout.Marker.allCases.map {
        ($0, WindowMarker($0))
    })
    private static let markerWidths = markers.mapValues(\.width)

    let firstWindowID: UInt64?
    let stripWidth: CGFloat
    private var windowSlots: [WindowIconSlot] = []
    private var continuationMarkers: [NSView] = []

    init(workspace: WorkspaceState.Workspace, maximumWidth: CGFloat, firstWindowID: UInt64?, icon: (String) -> NSImage) {
        let layout = WindowStripLayout(
            workspace: workspace, slotWidth: iconSlotWidth, markerWidths: Self.markerWidths
        )
        let visibleStrip = layout.visibleStrip(maximumWidth: maximumWidth, firstWindowID: firstWindowID)
        self.firstWindowID = visibleStrip.firstWindowID
        stripWidth = visibleStrip.width
        super.init(frame: .zero)

        orientation = .horizontal
        alignment = .centerY
        spacing = 0
        for item in visibleStrip.items {
            switch item {
            case .marker(let marker):
                guard let style = Self.markers[marker] else { continue }
                let view = style.makeView()
                if marker == .continuationLeft || marker == .continuationRight {
                    continuationMarkers.append(view)
                }
                addArrangedSubview(view)
            case .window(let window):
                let slot = WindowIconSlot(window: window, image: icon(window.appID))
                windowSlots.append(slot)
                addArrangedSubview(slot)
            }
        }
        widthAnchor.constraint(equalToConstant: stripWidth).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func windowID(at pointInWindow: NSPoint) -> UInt64? {
        windowSlots.first { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }?.windowID
    }

    func containsContinuationMarker(at pointInWindow: NSPoint) -> Bool {
        continuationMarkers.contains { $0.bounds.contains($0.convert(pointInWindow, from: nil)) }
    }

    func showWindowClickFeedback(id: UInt64, startedAt: CFTimeInterval) {
        windowSlots.first { $0.windowID == id }?.showClickFeedback(startedAt: startedAt)
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
