import AppKit

enum WindowStripWidth {
    static let range = 72...288
    static let defaultValue = 144
    private static let key = "maximumWindowStripWidthInMenuBar"

    static var value: Int {
        get { clamped(UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue) }
        set { UserDefaults.standard.set(clamped(newValue), forKey: key) }
    }

    private static func clamped(_ width: Int) -> Int {
        min(max(width, range.lowerBound), range.upperBound)
    }
}

@MainActor
final class WindowStripWidthMenuView: NSView {
    private final class Slider: NSSlider {
        private(set) var isTrackingMouse = false
        var trackingDidEnd: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            isTrackingMouse = true
            super.mouseDown(with: event)
            isTrackingMouse = false
            trackingDidEnd?()
        }
    }

    private let slider = Slider(frame: .zero)
    private let valueLabel = NSTextField(labelWithString: "")
    private let onCommit: (Int) -> Void

    init(title: String, width: Int, onCommit: @escaping (Int) -> Void) {
        self.onCommit = onCommit
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 54))
        autoresizingMask = [.width]

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .menuFont(ofSize: 0)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setAccessibilityElement(false)
        valueLabel.stringValue = formattedWidth(WindowStripWidth.range.upperBound)

        let heading = NSStackView(views: [titleLabel, valueLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.distribution = .fill
        heading.spacing = 12
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        valueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let horizontalInset: CGFloat = 18
        let headingWidth = titleLabel.intrinsicContentSize.width + valueLabel.intrinsicContentSize.width + heading.spacing
        frame.size.width = max(frame.width, ceil(headingWidth + 2 * horizontalInset))

        slider.minValue = Double(WindowStripWidth.range.lowerBound)
        slider.maxValue = Double(WindowStripWidth.range.upperBound)
        slider.integerValue = width
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.setAccessibilityLabel(title)
        slider.trackingDidEnd = { [weak self] in self?.commitWidth() }
        updateValueLabel()

        heading.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        addSubview(slider)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalInset),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            slider.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: heading.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc func focusSlider() {
        window?.makeFirstResponder(slider)
    }

    @objc private func sliderChanged() {
        if slider.isTrackingMouse {
            updateValueLabel()
        } else {
            commitWidth()
        }
    }

    private func formattedWidth(_ width: Int) -> String {
        String.localizedStringWithFormat(localized("menu.windowStripWidthValue"), width)
    }

    private func updateValueLabel() {
        valueLabel.stringValue = formattedWidth(slider.integerValue)
    }

    private func commitWidth() {
        let width = slider.integerValue
        slider.integerValue = width
        updateValueLabel()
        onCommit(width)
    }
}
