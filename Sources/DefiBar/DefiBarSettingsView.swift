import ServiceManagement
import SwiftUI

enum DisplaySetting: String, CaseIterable {
    // Raw values are UserDefaults keys and stay stable across releases.
    case workspaceIcons = "showsWorkspaceIconsInMenuBar"
    case hideWorkspaceLabelsWithIcons = "hidesWorkspaceLabelsWithIconsInMenuBar"
    case workspaceNames = "showsWorkspaceNames"
    case workspaceNumberSign = "showsWorkspaceNumberSign"
    case trailingWorkspaceIcon = "showsTrailingWorkspaceAsPlus"
    case activeWorkspaceWindows = "showsActiveWorkspaceWindowIconsInMenuBar"
    case workspaceSwitchHUD = "showsWorkspaceInfoOnSwitch"
    case applicationsInWorkspaceHUD = "showsAppIconsInWorkspaceInfo"

    var titleKey: String {
        switch self {
        case .workspaceIcons: return "settings.showWorkspaceIcons"
        case .hideWorkspaceLabelsWithIcons: return "settings.hideWorkspaceLabelsWithIcons"
        case .workspaceNames: return "settings.showWorkspaceNames"
        case .workspaceNumberSign: return "settings.showWorkspaceNumberSign"
        case .trailingWorkspaceIcon: return "settings.showTrailingWorkspaceIcon"
        case .activeWorkspaceWindows: return "settings.showActiveWorkspaceWindows"
        case .workspaceSwitchHUD: return "settings.showWorkspaceInfoOnSwitch"
        case .applicationsInWorkspaceHUD: return "settings.showApplicationsInWorkspaceInfo"
        }
    }

    var defaultValue: Bool { self != .hideWorkspaceLabelsWithIcons }
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: rawValue) }
}

enum InactiveWorkspaceLimit {
    static let key = "inactiveWorkspaceLimitPerSideInMenuBar"
    static let all = -1
    static let none = 0
    static let counts = 1...5
    static let defaultValue = 2

    static var value: Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue
    }
}

enum WindowStripWidth {
    static let range = 72...288
    static let defaultValue = 144
    private static let key = "maximumWindowStripWidthInMenuBar"

    static var value: Int {
        get { clamped(UserDefaults.standard.object(forKey: key) as? Int ?? defaultValue) }
        set { UserDefaults.standard.set(clamped(newValue), forKey: key) }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func clamped(_ width: Int) -> Int {
        min(max(width, range.lowerBound), range.upperBound)
    }
}

@MainActor
struct DefiBarSettingsView: View {
    let onLoginToggle: () -> Void
    let onDisplayChange: (DisplaySetting) -> Void
    let onInactiveWorkspaceLimitChange: () -> Void
    let onWidthChange: (Int) -> Void
    let onDisplayReset: () -> Void

    @State private var loginStatus = SMAppService.mainApp.status
    @AppStorage(InactiveWorkspaceLimit.key) private var inactiveWorkspaceLimit = InactiveWorkspaceLimit.defaultValue
    @State private var width = Double(WindowStripWidth.value)
    @State private var isAdjustingWidth = false

    var body: some View {
        Form {
            Section(localized("settings.general")) {
                Toggle(localized("settings.launchAtLogin"), isOn: Binding(
                    get: { loginStatus == .enabled },
                    set: { _ in
                        onLoginToggle()
                        loginStatus = SMAppService.mainApp.status
                    }
                ))
                if loginStatus == .requiresApproval {
                    Text(localized("settings.loginApprovalRequired"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(localized("settings.menuBar")) {
                Picker(localized("settings.inactiveWorkspaceLimit"), selection: Binding(
                    get: { inactiveWorkspaceLimit },
                    set: { limit in
                        inactiveWorkspaceLimit = limit
                        onInactiveWorkspaceLimitChange()
                    }
                )) {
                    Text(localized("settings.noAdjacentWorkspaces")).tag(InactiveWorkspaceLimit.none)
                    ForEach(InactiveWorkspaceLimit.counts, id: \.self) { count in
                        Text(count, format: .number).tag(count)
                    }
                    Text(localized("settings.allWorkspaces")).tag(InactiveWorkspaceLimit.all)
                }
                toggle(.workspaceIcons)
                toggle(.hideWorkspaceLabelsWithIcons)
                toggle(.workspaceNames)
                toggle(.workspaceNumberSign)
                toggle(.trailingWorkspaceIcon)
                toggle(.activeWorkspaceWindows)
                widthSlider
            }

            Section(localized("settings.workspaceInfo")) {
                toggle(.workspaceSwitchHUD)
                toggle(.applicationsInWorkspaceHUD)
            }

            Section {
                Button(localized("settings.resetDisplay")) {
                    onDisplayReset()
                    width = Double(WindowStripWidth.value)
                }
            }

            Section(localized("settings.about")) {
                LabeledContent(localized("settings.version")) {
                    Text(appVersion)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.checkbox)
        .frame(width: 560, height: 730)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
            if !isAdjustingWidth { width = Double(WindowStripWidth.value) }
        }
    }

    private var appVersion: String {
        let bundle = Bundle.main
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "—"
        }
        guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    private func toggle(_ setting: DisplaySetting) -> some View {
        DisplayToggle(setting: setting, onChange: onDisplayChange)
    }

    private var widthSlider: some View {
        let range = WindowStripWidth.range
        let title = localized("settings.windowStripMaximumWidth")
        let value = String.localizedStringWithFormat(localized("settings.windowStripWidthValue"), Int(width.rounded()))
        return HStack(spacing: 12) {
            Text(title)
                .fixedSize(horizontal: true, vertical: false)
            Slider(
                value: Binding(get: { width }, set: { newWidth in
                    width = newWidth
                    if !isAdjustingWidth { onWidthChange(Int(newWidth.rounded())) }
                }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                onEditingChanged: { editing in
                    isAdjustingWidth = editing
                    if !editing { onWidthChange(Int(width.rounded())) }
                }
            ) {
                Text(title)
            }
            .labelsHidden()
            .accessibilityValue(Text(value))
            Text(value)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private struct DisplayToggle: View {
        let setting: DisplaySetting
        let onChange: (DisplaySetting) -> Void
        @AppStorage private var isEnabled: Bool

        init(setting: DisplaySetting, onChange: @escaping (DisplaySetting) -> Void) {
            self.setting = setting
            self.onChange = onChange
            _isEnabled = AppStorage(wrappedValue: setting.defaultValue, setting.rawValue)
        }

        var body: some View {
            Toggle(localized(setting.titleKey), isOn: Binding(
                get: { isEnabled },
                set: { enabled in
                    isEnabled = enabled
                    onChange(setting)
                }
            ))
        }
    }
}
