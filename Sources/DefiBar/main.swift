import AppKit
import ServiceManagement
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

func localized(_ key: String) -> String {
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
        let nativeFullscreen: Bool?
    }

    struct Workspace: Decodable, Sendable {
        struct LabelStyle {
            let showsName: Bool
            let showsNumberSign: Bool
            let showsTrailingPlus: Bool
        }

        let id: String?
        let position: Int
        let name: String?
        let icon: String?
        let kind: String?
        let active: Bool
        let applications: [String]
        let focusedApplication: String?
        let windowCount: Int
        let windows: [Window]

        var tiledColumns: [[Window]] {
            let tiled = Dictionary(grouping: windows.filter { !$0.floating }) { $0.column ?? 0 }
            return tiled.keys.sorted().map { column in
                tiled[column, default: []].sorted { ($0.row ?? 0) < ($1.row ?? 0) }
            }
        }

        var symbolImage: NSImage? {
            guard kind != "trailing", name?.isEmpty == false, let icon else { return nil }
            return NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }

        func trailingPlusImage(
            style: LabelStyle, pointSize: CGFloat, weight: NSFont.Weight, accessibilityDescription: String? = nil
        ) -> NSImage? {
            guard kind == "trailing", style.showsTrailingPlus else { return nil }
            return NSImage(systemSymbolName: "plus", accessibilityDescription: accessibilityDescription)?
                .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        }

        func label(style: LabelStyle) -> String {
            let numberedLabel = style.showsNumberSign ? "#\(position)" : String(position)
            if kind == "trailing" { return style.showsTrailingPlus ? "+" : numberedLabel }
            guard style.showsName, kind != "ordinary", let name, !name.isEmpty else { return numberedLabel }
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

    static func windowTitle(for id: UInt64) throws -> String? {
        struct WindowList: Decodable {
            struct Window: Decodable {
                let id: UInt64
                let title: String?
            }

            let windows: [Window]
        }

        let data = try run(["list-windows", "--json"])
        let list = try JSONDecoder().decode(WindowList.self, from: data)
        return list.windows.first { $0.id == id }?.title
    }

    static func run(_ arguments: [String], timeout: TimeInterval = 3) throws -> Data {
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
        let terminateProcess = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminateProcess)
        defer { terminateProcess.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.unavailable }
        return data
    }
}

private final class StatusRow: NSStackView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class DefiBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private struct WindowStripWorkspace: Equatable {
        let monitorID: UInt32
        let workspaceID: String?
        let position: Int?

        init(monitorID: UInt32, workspace: WorkspaceState.Workspace) {
            self.monitorID = monitorID
            workspaceID = workspace.id
            position = workspace.id == nil ? workspace.position : nil
        }
    }

    private struct WindowStripState {
        let workspace: WindowStripWorkspace
        var gesture = WindowStripScrollGesture.idle
    }

    // The bundle identifier and notification prefix differ across Defi versions.
    private static let defiIdentifiers = ["com.qeude.defi", "com.quentin.defi"]
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let row = StatusRow()
    private var state: WorkspaceState?
    private var revision = 0
    private var reading = false
    private var refreshPending = false
    private var switching = false
    private var changingDefiService = false
    private var lastClick: (display: Int, position: Int, time: CFTimeInterval)?
    private var lastWindowClick: (id: UInt64, time: CFTimeInterval)?
    private var windowStripState: WindowStripState?
    private var scrollEventMonitors: [Any] = []
    private let workspaceHUD = WorkspaceHUD()
    private var settingsWindow: NSWindow?
    private var icons: [String: NSImage] = [:]
    private var connectionStatusKey = "status.connecting"
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else {
            return nil
        }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }()

    private lazy var connectingIcon = makeConnectionIcon(showsWarning: false)
    private lazy var warningIcon = makeConnectionIcon(showsWarning: true)

    private func makeConnectionIcon(showsWarning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let outline = NSBezierPath(
                roundedRect: NSRect(x: 0.75, y: 3.75, width: 18.5, height: 8.5),
                xRadius: 3, yRadius: 3
            )
            outline.lineWidth = 1.5
            outline.stroke()
            for x in [3.0, 7.5, 13.0] {
                NSBezierPath(
                    roundedRect: NSRect(x: x, y: 6, width: x == 7.5 ? 5 : 4, height: 4),
                    xRadius: 1, yRadius: 1
                ).fill()
            }
            if showsWarning {
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 8, height: 8)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSBezierPath(roundedRect: NSRect(x: 15.5, y: 3.5, width: 1.5, height: 4),
                             xRadius: 0.75, yRadius: 0.75).fill()
                NSBezierPath(ovalIn: NSRect(x: 15.5, y: 1, width: 1.5, height: 1.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: Dictionary(
            uniqueKeysWithValues: DisplaySetting.allCases.map { ($0.rawValue, $0.defaultValue) }
        ))
        _ = updaterController
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
        let localScroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.scrollWindowStrip(with: event) == true }
            return handled ? nil : event
        }
        // The system can deliver a scroll over the status item to the foreground application.
        let globalScroll = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.scrollWindowStrip(with: event) }
        }
        scrollEventMonitors = [localScroll, globalScroll].compactMap { $0 }

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

    func applicationWillTerminate(_ notification: Notification) {
        scrollEventMonitors.forEach(NSEvent.removeMonitor)
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
                    connectionStatusKey = "status.cliMissing"
                    render()
                case .failure:
                    state = nil
                    connectionStatusKey = "status.connectionFailed"
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

        guard DisplaySetting.workspaceSwitchHUD.isEnabled, let previousPosition, let monitor = focusedMonitor,
              let workspace = monitor.workspaces.first(where: \.active),
              previousMonitor?.id != monitor.id || previousPosition != workspace.position else { return }

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == monitor.id
        } ?? item.button?.window?.screen ?? NSScreen.main
        guard let screen else { return }
        workspaceHUD.show(
            workspace,
            labelStyle: workspaceLabelStyle,
            showsApplications: DisplaySetting.applicationsInWorkspaceHUD.isEnabled,
            appIcon: icon(for:),
            on: screen
        )
    }

    private var visibleWorkspaces: [WorkspaceState.Workspace] {
        let workspaces = (focusedMonitor?.workspaces ?? []).sorted { $0.position < $1.position }
        let limit = InactiveWorkspaceLimit.value
        guard limit == InactiveWorkspaceLimit.none || InactiveWorkspaceLimit.counts.contains(limit) else {
            return workspaces
        }
        guard let activeIndex = workspaces.firstIndex(where: \.active) else { return [] }
        let start = max(workspaces.startIndex, activeIndex - limit)
        let end = min(workspaces.endIndex, activeIndex + limit + 1)
        return Array(workspaces[start..<end])
    }

    private var workspaceLabelStyle: WorkspaceState.Workspace.LabelStyle {
        .init(
            showsName: DisplaySetting.workspaceNames.isEnabled,
            showsNumberSign: DisplaySetting.workspaceNumberSign.isEnabled,
            showsTrailingPlus: DisplaySetting.trailingWorkspaceIcon.isEnabled
        )
    }

    private func unavailableStatus(hasVisibleWorkspaces: Bool) -> String? {
        guard state != nil else { return localized(connectionStatusKey) }
        guard hasVisibleWorkspaces else { return localized("status.noWorkspaces") }
        return nil
    }

    private var activeWindowStrip: WindowStripView? {
        row.arrangedSubviews.lazy.compactMap { ($0 as? WorkspaceButton)?.windowStrip }.first
    }

    private func render(preservingWindowStripPosition: Bool = true) {
        guard let statusButton = item.button else { return }
        // Capture the live offset, including any animation progress, before replacing the strip.
        let previousPosition = preservingWindowStripPosition ? activeWindowStrip?.position : nil
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let workspaces = visibleWorkspaces
        let status = unavailableStatus(hasVisibleWorkspaces: !workspaces.isEmpty)
        statusButton.toolTip = status
        if let status {
            windowStripState = nil
            statusButton.image = state == nil && connectionStatusKey == "status.connecting"
                ? connectingIcon : warningIcon
            statusButton.imagePosition = .imageOnly
            statusButton.title = ""
            statusButton.setAccessibilityLabel("DefiBar · \(status)")
            item.length = NSStatusItem.squareLength
            return
        }

        statusButton.image = nil
        statusButton.title = ""
        statusButton.setAccessibilityLabel("DefiBar")
        guard let monitor = focusedMonitor else { return }
        let labelStyle = workspaceLabelStyle
        let showsWorkspaceIcons = DisplaySetting.workspaceIcons.isEnabled
        let hidesLabelsWithIcons = DisplaySetting.hideWorkspaceLabelsWithIcons.isEnabled
        let showsActiveWorkspaceWindows = DisplaySetting.activeWorkspaceWindows.isEnabled
        let windowStripMaximumWidth = CGFloat(WindowStripWidth.value)
        let stripWorkspace = showsActiveWorkspaceWindows ? workspaces.first(where: \.active).map {
            WindowStripWorkspace(monitorID: monitor.id, workspace: $0)
        } : nil
        let sameStripWorkspace = windowStripState?.workspace == stripWorkspace
        if !sameStripWorkspace {
            windowStripState = stripWorkspace.map { WindowStripState(workspace: $0) }
        }
        let positionToRestore = sameStripWorkspace ? previousPosition : nil
        for workspace in workspaces {
            let button = WorkspaceButton(
                workspace: workspace, display: monitor.display,
                labelStyle: labelStyle, showsWorkspaceIcon: showsWorkspaceIcons,
                hidesLabelWithIcon: hidesLabelsWithIcons,
                showsActiveWorkspaceWindows: showsActiveWorkspaceWindows,
                windowStripMaximumWidth: windowStripMaximumWidth,
                windowStripPosition: workspace.active ? positionToRestore : nil,
                icon: { [weak self] appID in self?.icon(for: appID) ?? NSWorkspace.shared.icon(for: .application) }
            )
            if workspace.active, positionToRestore?.focusedWindowID != button.windowStrip?.position.focusedWindowID {
                windowStripState?.gesture = .idle
            }
            button.target = self
            button.action = #selector(switchWorkspace(_:))
            row.addArrangedSubview(button)
            if let lastWindowClick, CACurrentMediaTime() - lastWindowClick.time < clickFeedbackDuration {
                button.windowStrip?.showWindowClickFeedback(id: lastWindowClick.id, startedAt: lastWindowClick.time)
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

    private func scrollWindowStrip(with event: NSEvent) -> Bool {
        guard item.menu == nil, let window = item.button?.window,
              let strip = activeWindowStrip,
              strip.canScroll else {
            windowStripState?.gesture = .idle
            return false
        }
        let point = event.window === window
            ? event.locationInWindow : window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let horizontalDelta = event.scrollingDeltaX
        guard windowStripState?.gesture.shouldScroll(
            phase: event.phase, momentum: event.momentumPhase, isOverStrip: strip.contains(point),
            hasHorizontalMovement: horizontalDelta != 0, hasPreciseDeltas: event.hasPreciseScrollingDeltas
        ) == true else { return false }

        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 18
        return strip.scrollHorizontally(by: -horizontalDelta * scale)
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
            if workspace.windowStrip?.containsContinuationMarker(at: pointInWindow) == true { return }
            if let strip = workspace.windowStrip, let id = strip.windowID(at: pointInWindow) {
                guard !switching else { return }
                let time = CACurrentMediaTime()
                lastWindowClick = (id, time)
                strip.showWindowClickFeedback(id: id, startedAt: time)
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

    @objc private func startDefi() {
        changeDefiService("start")
    }

    @objc private func stopDefi() {
        changeDefiService("stop")
    }

    private func changeDefiService(_ command: String) {
        guard !changingDefiService else { return }
        changingDefiService = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                // Defi's stop command waits for window restoration and daemon shutdown.
                Result { try DefiClient.run(["service", command], timeout: 15) }
            }.value
            changingDefiService = false
            if case .failure(let error) = result {
                NSLog("DefiBar: Defi service %@ failed: %@", command, String(describing: error))
                NSSound.beep()
            }
            refresh()
        }
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            NSLog("DefiBar: could not change launch at login: %@", String(describing: error))
            NSSound.beep()
        }
    }

    private func displaySettingChanged(_ setting: DisplaySetting) {
        switch setting {
        case .workspaceSwitchHUD:
            if !setting.isEnabled { workspaceHUD.dismiss() }
        case .applicationsInWorkspaceHUD:
            break
        default:
            render()
        }
    }

    private func setWindowStripWidth(_ width: Int) {
        guard width != WindowStripWidth.value else { return }
        WindowStripWidth.value = width
        windowStripState?.gesture = .idle
        render(preservingWindowStripPosition: false)
    }

    private func resetDisplaySettings() {
        let previousWidth = WindowStripWidth.value
        for setting in DisplaySetting.allCases {
            UserDefaults.standard.removeObject(forKey: setting.rawValue)
        }
        UserDefaults.standard.removeObject(forKey: InactiveWorkspaceLimit.key)
        WindowStripWidth.reset()
        workspaceHUD.dismiss()

        let widthChanged = previousWidth != WindowStripWidth.value
        if widthChanged { windowStripState?.gesture = .idle }
        render(preservingWindowStripPosition: !widthChanged)
    }

    @objc private func openDefiBarSettings() {
        if let settingsWindow {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = DefiBarSettingsView(
            onLoginToggle: { [weak self] in self?.toggleLaunchAtLogin() },
            onDisplayChange: { [weak self] setting in self?.displaySettingChanged(setting) },
            onInactiveWorkspaceLimitChange: { [weak self] in self?.render() },
            onWidthChange: { [weak self] width in self?.setWindowStripWidth(width) },
            onDisplayReset: { [weak self] in self?.resetDisplaySettings() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: settingsView))
        window.styleMask = [.titled, .closable]
        window.title = localized("settings.title")
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func showMenu() {
        guard item.menu == nil, let button = item.button else { return }
        windowStripState?.gesture = .idle
        let menu = NSMenu()
        menu.delegate = self
        if let updaterController {
            let update = menu.addItem(
                withTitle: localized("menu.checkForUpdates"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            update.target = updaterController
        }
        let preferences = menu.addItem(
            withTitle: localized("menu.defiBarSettings"),
            action: #selector(openDefiBarSettings),
            keyEquivalent: ""
        )
        preferences.target = self
        menu.addItem(.separator())
        if let status = unavailableStatus(hasVisibleWorkspaces: !visibleWorkspaces.isEmpty) {
            let statusItem = menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(.separator())
        }
        let start = menu.addItem(
            withTitle: localized("menu.startDefi"), action: changingDefiService ? nil : #selector(startDefi), keyEquivalent: ""
        )
        start.target = self
        let stop = menu.addItem(
            withTitle: localized("menu.stopDefi"), action: changingDefiService ? nil : #selector(stopDefi), keyEquivalent: ""
        )
        stop.target = self
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
