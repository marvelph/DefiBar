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

    struct Workspace: Decodable, Sendable {
        let position: Int
        let name: String?
        let icon: String?
        let kind: String?
        let active: Bool
        let applications: [String]
        let focusedApplication: String?
        let windowCount: Int

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
private let workspaceButtonHeight: CGFloat = 22

@MainActor
private final class AppIconSlot: NSView {
    var showsFocus = false

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

    init(
        workspace: WorkspaceState.Workspace,
        display: Int,
        icons: [(bundleID: String, image: NSImage)]
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
        layer?.borderColor = (workspace.active ? activeWorkspaceBorderColor : NSColor.systemGray.withAlphaComponent(0.65)).cgColor
        layer?.backgroundColor = (workspace.active ? NSColor.systemBlue : NSColor.systemGray).withAlphaComponent(0.20).cgColor

        let label = NSTextField(labelWithString: workspace.label)
        label.font = .systemFont(ofSize: 12, weight: workspace.active ? .semibold : .medium)
        let horizontalInset: CGFloat = 6
        let iconSize: CGFloat = 14
        let iconSlotWidth: CGFloat = 18
        let labelSpacing: CGFloat = 2
        let images = icons.map { icon in
            let view = NSImageView(image: icon.image)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.translatesAutoresizingMaskIntoConstraints = false
            let slot = AppIconSlot(frame: .zero)
            slot.showsFocus = icon.bundleID == workspace.focusedApplication
            slot.addSubview(view)
            NSLayoutConstraint.activate([
                slot.widthAnchor.constraint(equalToConstant: iconSlotWidth),
                slot.heightAnchor.constraint(equalToConstant: workspaceButtonHeight),
                view.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: iconSize),
                view.heightAnchor.constraint(equalToConstant: iconSize)
            ])
            return slot
        }
        let content = NSStackView(views: [label] + images)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 0
        content.setCustomSpacing(labelSpacing, after: label)
        let isTrailing = workspace.kind == "trailing"
        var workspaceLabelWidth = ceil(label.intrinsicContentSize.width)
        if !isTrailing, workspace.name?.isEmpty == false, let symbol = workspace.icon,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
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
        let iconWidth = icons.isEmpty ? 0 : labelSpacing + CGFloat(icons.count) * iconSlotWidth
        // Keep the frame tied to its contents when the status bar lays out the row again.
        let buttonWidth = workspaceLabelWidth + iconWidth + 2 * horizontalInset
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
        if let bundleID = workspace.focusedApplication, icons.contains(where: { $0.bundleID == bundleID }) {
            let name = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
                ?? bundleID
            setAccessibilityValue(String(format: localized("workspace.selectedApp"), name))
        }
        setAccessibilityHelp(workspace.active ? localized("workspace.active") : localized("workspace.switch"))
    }

    required init?(coder: NSCoder) { nil }

    func showClickFeedback(startedAt: CFTimeInterval) {
        let duration = 0.40
        guard let layer, CACurrentMediaTime() - startedAt < duration else { return }
        let feedback = CAKeyframeAnimation(keyPath: "borderWidth")
        feedback.values = [3.0, 3.0, layer.borderWidth]
        feedback.keyTimes = [0, 0.60, 1]
        feedback.beginTime = layer.convertTime(startedAt, from: nil)
        feedback.duration = duration
        layer.add(feedback, forKey: "clickFeedback")
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
        state = updated
        render()
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
                    state = updated
                case .failure(DefiClient.Failure.cliMissing):
                    state = nil
                    message = localized("status.cliMissing")
                case .failure:
                    state = nil
                    message = localized("status.connectionFailed")
                }
                render()
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
            var seen = Set<String>()
            let appIcons: [(bundleID: String, image: NSImage)] = workspace.active
                ? workspace.applications.filter { seen.insert($0).inserted }.map { ($0, icon(for: $0)) }
                : []
            let button = WorkspaceButton(
                workspace: workspace, display: monitor.display, icons: appIcons
            )
            button.target = self
            button.action = #selector(switchWorkspace(_:))
            row.addArrangedSubview(button)
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
            switchWorkspace(workspace)
        }
    }

    @objc private func switchWorkspace(_ sender: WorkspaceButton) {
        let time = CACurrentMediaTime()
        lastClick = (sender.display, sender.position, time)
        sender.showClickFeedback(startedAt: time)
        guard !sender.isActive, !switching else { return }
        switching = true
        let arguments = ["--monitor", String(sender.display), "focus-workspace-position", String(sender.position)]
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DefiClient.run(arguments) }
            }.value
            switching = false
            if case .failure(let error) = result {
                NSLog("DefiBar: workspace switch failed: %@", String(describing: error))
                NSSound.beep()
            }
            refresh()
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
