import AppKit

@MainActor
final class WindowIconSlot: NSView {
    static let slotWidth: CGFloat = 18

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
            widthAnchor.constraint(equalToConstant: Self.slotWidth),
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
struct WindowMarker {
    private static let pointSize: CGFloat = 10
    private static let font = NSFont.systemFont(ofSize: pointSize, weight: .medium)
    private let text: String
    private let image: NSImage?
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
            .withSymbolConfiguration(.init(pointSize: Self.pointSize, weight: .medium))
        if let image {
            width = ceil(image.size.width)
        } else {
            width = ceil((text as NSString).size(withAttributes: [.font: Self.font]).width)
        }
    }

    func makeView() -> NSView {
        let view: NSView
        if let image {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .labelColor
            view = icon
        } else {
            view = WindowMarkerText(text: text, font: Self.font)
        }
        view.alphaValue = 0.65
        view.setAccessibilityElement(false)
        view.translatesAutoresizingMaskIntoConstraints = false

        let slot = NSView(frame: NSRect(x: 0, y: 0, width: width, height: workspaceButtonHeight))
        slot.setAccessibilityElement(false)
        slot.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            view.widthAnchor.constraint(equalTo: slot.widthAnchor)
        ])
        return slot
    }
}

@MainActor
private final class WindowMarkerText: NSView {
    private let text: NSString
    private let font: NSFont
    private let textSize: NSSize

    init(text: String, font: NSFont) {
        self.text = text as NSString
        self.font = font
        textSize = (text as NSString).size(withAttributes: [.font: font])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(textSize.width), height: ceil(textSize.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let origin = NSPoint(x: bounds.midX - textSize.width / 2, y: bounds.midY - textSize.height / 2)
        text.draw(at: origin, withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
    }
}
