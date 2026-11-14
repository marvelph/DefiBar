import AppKit
import UniformTypeIdentifiers

private func localized(_ key: String) -> String {
    let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
    return bundle.localizedString(forKey: key, value: nil, table: nil)
}

struct WorkspaceState: Decodable, Sendable {
    let focusedMonitorID: UInt32?

    struct Monitor: Decodable, Sendable {
        let id: UInt32
        let display: Int
        let focused: Bool
        let workspaces: [Workspace]
    }

    struct Window: Decodable, Sendable {
        let id: UInt64
        let appID: String
        let column: Int?
        let row: Int?
        let floating: Bool
        let selected: Bool
    }

    struct Workspace: Decodable, Sendable {
        let position: Int
        let name: String?
        let icon: String?
        let kind: String?
        let active: Bool
        let applications: [String]
        let focusedApplication: String?
        let windowCount: Int
        let windows: [Window]?

        var tiledColumns: [[Window]] {
            guard let windows else { return [] }
            let tiled = Dictionary(grouping: windows.filter { !$0.floating }) { $0.column ?? 0 }
            return tiled.keys.sorted().map { column in
                tiled[column, default: []].sorted { ($0.row ?? 0) < ($1.row ?? 0) }
            }
        }

        var symbolImage: NSImage? {
            guard kind != "trailing", name?.isEmpty == false, let icon else { return nil }
            return NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }

        var label: String {
            if kind == "trailing" { return "+" }
            guard let name, !name.isEmpty else { return String(position) }
            return name
        }
    }

    let monitors: [Monitor]
}

enum DefiClient {
    enum Failure: Error {
        case cliMissing
        case unavailable
    }

    static func read() throws -> WorkspaceState {
        try decode(run(["list-workspaces", "--json"]))
    }

    static func decode(_ data: Data) throws -> WorkspaceState {
        try JSONDecoder().decode(WorkspaceState.self, from: data)
    }

    static func run(_ arguments: [String]) throws -> Data {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = ProcessInfo.processInfo.environment
        let searchPath = environment["PATH", default: ""]
        let directories = searchPath.split(separator: ":")
            .map(String.init).filter { $0.hasPrefix("/") }
        let candidates = [
            environment["DEFI_BIN"],
            "\(home)/Applications/Defi.app/Contents/MacOS/defi",
            "/Applications/Defi.app/Contents/MacOS/defi"
        ].compactMap { $0 } + directories.map { "\($0)/defi" }

        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure.cliMissing
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Bound the read if Defi stops responding to the CLI.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unavailable }
        return data
    }
}

private let activeWorkspaceBorderColor = NSColor.systemBlue.withAlphaComponent(0.65)
private var windowGroupMarkerColor: NSColor { NSColor.labelColor.withAlphaComponent(0.35) }
private let workspaceButtonHeight: CGFloat = 22

private let clickFeedbackDuration = 0.40

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
private final class WorkspaceButton: NSButton {
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
        let iconSize: CGFloat = 14
        let iconSlotWidth: CGFloat = 18
        let labelSpacing: CGFloat = 2
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
            if let window {
                let appName = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first?.localizedName
                    ?? appID
                slot.toolTip = "\(appName) · #\(window.id)"
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
            let bracket = NSTextField(labelWithString: text)
            bracket.font = .systemFont(ofSize: 13, weight: .medium)
            bracket.textColor = windowGroupMarkerColor
            bracket.alignment = .center
            bracket.setAccessibilityElement(false)
            let width = ceil(bracket.intrinsicContentSize.width)
            let marker = NSView()
            marker.addSubview(bracket)
            bracket.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                marker.widthAnchor.constraint(equalToConstant: width),
                marker.heightAnchor.constraint(equalToConstant: workspaceButtonHeight),
                bracket.leadingAnchor.constraint(equalTo: marker.leadingAnchor),
                bracket.trailingAnchor.constraint(equalTo: marker.trailingAnchor),
                bracket.centerYAnchor.constraint(equalTo: marker.centerYAnchor, constant: -1)
            ])
            iconViews.append(marker)
            iconWidth += width
        }

        if workspace.active {
            if let windows = workspace.windows {
                for column in workspace.tiledColumns {
                    let stacked = column.count > 1
                    if stacked { appendWindowGroupMarker("(") }
                    for window in column {
                        appendSlot(makeSlot(appID: window.appID, window: window))
                    }
                    if stacked { appendWindowGroupMarker(")") }
                }
                let floating = windows.filter(\.floating)
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
        }

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

private final class StatusRow: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class DefiBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    // The bundle identifier and notification prefix differ across Defi versions.
    private static let defiIdentifiers = ["com.qeude.defi", "com.quentin.defi"]
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let row = StatusRow()
    private var state: WorkspaceState?
    private var revision = 0
    private var reading = false
    private var refreshPending = false
    private var switching = false
    private var lastClick: (display: Int, position: Int, time: CFTimeInterval)?
    private var lastWindowClick: (id: UInt64, time: CFTimeInterval)?
    private let workspaceHUD = WorkspaceHUD()
    private var icons: [String: NSImage] = [:]
    private var message = localized("status.connecting")

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityHelp(localized("status.menuHelp"))
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        row.autoresizingMask = [.width, .height]
        row.frame = button.bounds
        button.addSubview(row)

        render()

        let center = DistributedNotificationCenter.default()
        for prefix in Self.defiIdentifiers {
            center.addObserver(
                self, selector: #selector(workspaceChanged(_:)),
                name: Notification.Name("\(prefix).workspaceChanged"),
                object: nil, suspensionBehavior: .deliverImmediately
            )
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil
        )
        refresh()
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        let payload = (notification.object as? String)
            ?? (notification.userInfo?["json"] as? String)
        let data = payload.map { Data($0.utf8) }
            ?? notification.userInfo.flatMap { info in
                guard JSONSerialization.isValidJSONObject(info) else { return nil }
                return try? JSONSerialization.data(withJSONObject: info)
            }
        guard let data, let updated = try? DefiClient.decode(data) else {
            refresh()
            return
        }

        revision += 1
        applyState(updated)
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let identifier = app?.bundleIdentifier, Self.defiIdentifiers.contains(identifier) else { return }
        refresh()
    }

    private func refresh() {
        guard !reading else {
            refreshPending = true
            return
        }
        reading = true
        let requestedRevision = revision
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try DefiClient.read() }
            }.value
            if requestedRevision == revision {
                switch result {
                case .success(let updated):
                    applyState(updated)
                case .failure(DefiClient.Failure.cliMissing):
                    state = nil
                    message = localized("status.cliMissing")
                    render()
                case .failure:
                    state = nil
                    message = localized("status.connectionFailed")
                    render()
                }
            }

            reading = false
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    private var focusedMonitor: WorkspaceState.Monitor? {
        state?.monitors.first { $0.id == state?.focusedMonitorID }
            ?? state?.monitors.first(where: \.focused)
    }

    private func applyState(_ updated: WorkspaceState) {
        let previousMonitor = focusedMonitor
        let previousPosition = previousMonitor?.workspaces.first(where: \.active)?.position
        state = updated
        render()

        guard let previousPosition, let monitor = focusedMonitor,
              let workspace = monitor.workspaces.first(where: \.active),
              previousMonitor?.id != monitor.id || previousPosition != workspace.position else { return }

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == monitor.id
        } ?? item.button?.window?.screen ?? NSScreen.main
        guard let screen else { return }
        workspaceHUD.show(workspace.label, icon: workspace.symbolImage, on: screen)
    }

    private var unavailableStatus: String? {
        guard state != nil else { return message }
        guard focusedMonitor?.workspaces.isEmpty == false else { return localized("status.noWorkspaces") }
        return nil
    }

    private func render() {
        guard let statusButton = item.button else { return }
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let status = unavailableStatus
        statusButton.toolTip = status
        if let status {
            let image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "DefiBar")
            image?.isTemplate = true
            statusButton.image = image
            statusButton.imagePosition = image == nil ? .noImage : .imageOnly
            statusButton.title = image == nil ? "DefiBar" : ""
            statusButton.setAccessibilityLabel("DefiBar · \(status)")
            item.length = image == nil ? NSStatusItem.variableLength : NSStatusItem.squareLength
            return
        }

        statusButton.image = nil
        statusButton.title = ""
        statusButton.setAccessibilityLabel("DefiBar")
        guard let monitor = focusedMonitor else { return }
        for workspace in monitor.workspaces.sorted(by: { $0.position < $1.position }) {
            let button = WorkspaceButton(
                workspace: workspace, display: monitor.display, icon: icon(for:)
            )
            button.target = self
            button.action = #selector(switchWorkspace(_:))
            row.addArrangedSubview(button)
            if let lastWindowClick, CACurrentMediaTime() - lastWindowClick.time < clickFeedbackDuration {
                button.showWindowClickFeedback(id: lastWindowClick.id, startedAt: lastWindowClick.time)
            }
            if let lastClick, lastClick.display == monitor.display, lastClick.position == workspace.position {
                button.showClickFeedback(startedAt: lastClick.time)
            }
        }
        item.length = ceil(row.fittingSize.width)
    }

    private func icon(for bundleID: String) -> NSImage {
        if let icon = icons[bundleID] { return icon }
        let workspace = NSWorkspace.shared
        let url = workspace.runningApplications.first { $0.bundleIdentifier == bundleID }?.bundleURL
            ?? workspace.urlForApplication(withBundleIdentifier: bundleID)
        guard let url else { return workspace.icon(for: .application) }
        let icon = workspace.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        guard let window = sender.window else { return }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard sender.bounds.contains(sender.convert(pointInWindow, from: nil)) else {
            showMenu()
            return
        }
        let clicked = row.arrangedSubviews.first { view in
            view.bounds.contains(view.convert(pointInWindow, from: nil))
        }
        if let workspace = clicked as? WorkspaceButton {
            if let id = workspace.windowID(at: pointInWindow) {
                guard !switching else { return }
                let time = CACurrentMediaTime()
                lastWindowClick = (id, time)
                workspace.showWindowClickFeedback(id: id, startedAt: time)
                switchFocus(arguments: ["focus-window-id", String(id)])
            } else {
                switchWorkspace(workspace)
            }
        }
    }

    @objc private func switchWorkspace(_ sender: WorkspaceButton) {
        let time = CACurrentMediaTime()
        lastClick = (sender.display, sender.position, time)
        sender.showClickFeedback(startedAt: time)
        guard !sender.isActive else { return }
        switchFocus(arguments: ["--monitor", String(sender.display), "focus-workspace-position", String(sender.position)])
    }

    private func switchFocus(arguments: [String]) {
        guard !switching else { return }
        switching = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DefiClient.run(arguments) }
            }.value
            switching = false
            if case .failure(let error) = result {
                NSLog("DefiBar: focus switch failed: %@", String(describing: error))
                NSSound.beep()
            }
        }
    }

    @objc private func openDefiSettings() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DefiClient.run(["open-settings"]) }
            }.value
            if case .failure(let error) = result {
                NSLog("DefiBar: could not open Defi settings: %@", String(describing: error))
                NSSound.beep()
            }
        }
    }

    private func showMenu() {
        guard item.menu == nil, let button = item.button else { return }
        let menu = NSMenu()
        menu.delegate = self
        if let status = unavailableStatus {
            let statusItem = menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(.separator())
        }
        let settings = menu.addItem(withTitle: localized("menu.settings"), action: #selector(openDefiSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: localized("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        item.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        if item.menu === menu {
            item.menu = nil
        }
    }

    static func run() {
        let application = NSApplication.shared
        let delegate = DefiBar()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

MainActor.assumeIsolated { DefiBar.run() }
