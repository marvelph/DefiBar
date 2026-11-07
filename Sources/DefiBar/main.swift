import AppKit
import UniformTypeIdentifiers

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
        let active: Bool
        let applications: [String]
        let windowCount: Int

        var label: String {
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

@MainActor
private final class WorkspaceButton: NSButton {
    let display: Int
    let position: Int
    let isActive: Bool

    init(workspace: WorkspaceState.Workspace, display: Int, icons: [NSImage]) {
        self.display = display
        position = workspace.position
        isActive = workspace.active
        super.init(frame: .zero)

        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = (workspace.active ? NSColor.systemBlue : NSColor.systemGray).withAlphaComponent(0.65).cgColor
        layer?.backgroundColor = (workspace.active ? NSColor.systemBlue : NSColor.systemGray).withAlphaComponent(0.20).cgColor

        let label = NSTextField(labelWithString: workspace.label)
        label.font = .systemFont(ofSize: 12, weight: workspace.active ? .semibold : .medium)
        let images = icons.map { icon in
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 14),
                view.heightAnchor.constraint(equalToConstant: 14)
            ])
            return view
        }
        let content = NSStackView(views: [label] + images)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 22)
        ])

        toolTip = "\(workspace.label) · ウインドウ \(workspace.windowCount) 件"
        setAccessibilityLabel(workspace.label)
        setAccessibilityHelp(workspace.active ? "アクティブなワークスペース" : "このワークスペースに切り替え")
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
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let row = StatusRow()
    private var state: WorkspaceState?
    private var revision = 0
    private var reading = false
    private var refreshPending = false
    private var switching = false
    private var lastClick: (display: Int, position: Int, time: CFTimeInterval)?
    private var icons: [String: NSImage] = [:]
    private var message = "Defi に接続中…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel("DefiBar")
        button.setAccessibilityHelp("右クリックで DefiBar メニューを開く")
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.autoresizingMask = [.width, .height]
        row.frame = button.bounds
        button.addSubview(row)

        render()

        let center = DistributedNotificationCenter.default()
        // The notification prefix differs across Defi versions.
        for prefix in ["com.qeude.defi", "com.quentin.defi"] {
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
        guard let payload, let updated = try? DefiClient.decode(Data(payload.utf8)) else {
            refresh()
            return
        }

        revision += 1
        state = updated
        render()
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        guard let identifier = app?.bundleIdentifier, ["com.qeude.defi", "com.quentin.defi"].contains(identifier) else { return }
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
                    message = "ワークスペースがありません"
                case .failure(DefiClient.Failure.cliMissing):
                    state = nil
                    message = "Defi CLI が見つかりません"
                case .failure:
                    state = nil
                    message = "Defi に接続できません"
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
        guard focusedMonitor?.workspaces.isEmpty == false else { return "ワークスペースがありません" }
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
            let appIcons = workspace.active
                ? workspace.applications.filter { seen.insert($0).inserted }.map { icon(for: $0) }
                : []
            let button = WorkspaceButton(workspace: workspace, display: monitor.display, icons: appIcons)
            button.target = self
            button.action = #selector(switchWorkspace(_:))
            row.addArrangedSubview(button)
            if let lastClick, lastClick.display == monitor.display, lastClick.position == workspace.position {
                button.showClickFeedback(startedAt: lastClick.time)
            }
        }
        item.length = ceil(row.fittingSize.width) + 4
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

    @objc private func quitDefi() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DefiClient.run(["quit"]) }
            }.value
            if case .failure(let error) = result {
                NSLog("DefiBar: could not quit Defi: %@", String(describing: error))
                NSSound.beep()
            }
            refresh()
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
        let quitDefiItem = menu.addItem(withTitle: "Defi を終了", action: #selector(quitDefi), keyEquivalent: "")
        quitDefiItem.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "DefiBar を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
