import AppKit
import ServiceManagement
import SwiftUI

/// Which number the menu bar shows next to each service.
enum MenuBarNumber: String, CaseIterable, Identifiable {
    case highest, fiveHour, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highest: return L("The most used limit")
        case .fiveHour: return L("5 hours")
        case .week: return L("Week")
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let refreshChoices = [2, 5, 10, 15]

    private static let defaults = UserDefaults.standard

    @Published var enabledProviders: Set<ProviderID> {
        didSet { Self.defaults.set(enabledProviders.map(\.rawValue), forKey: "settings.providers") }
    }
    @Published var refreshMinutes: Int {
        didSet { Self.defaults.set(refreshMinutes, forKey: "settings.refreshMinutes") }
    }
    @Published var menuBarNumber: MenuBarNumber {
        didSet { Self.defaults.set(menuBarNumber.rawValue, forKey: "settings.menuBarNumber") }
    }
    @Published var notifyThresholds: Bool {
        didSet { Self.defaults.set(notifyThresholds, forKey: "settings.notifyThresholds") }
    }
    @Published var notifyResets: Bool {
        didSet { Self.defaults.set(notifyResets, forKey: "settings.notifyResets") }
    }
    @Published var notifyFinished: Bool {
        didSet { Self.defaults.set(notifyFinished, forKey: "settings.notifyFinished") }
    }
    @Published var notifyWeekly: Bool {
        didSet { Self.defaults.set(notifyWeekly, forKey: "settings.notifyWeekly") }
    }
    @Published var showHistory: Bool {
        didSet { Self.defaults.set(showHistory, forKey: "settings.showHistory") }
    }
    @Published var showValue: Bool {
        didSet { Self.defaults.set(showValue, forKey: "settings.showValue") }
    }
    /// Dollars or euros for the value at API prices (see Currency); the default follows the Mac's region.
    @Published var currency: Currency {
        didSet { Self.defaults.set(currency.rawValue, forKey: Currency.defaultsKey) }
    }
    @Published var checkServiceStatus: Bool {
        didSet { Self.defaults.set(checkServiceStatus, forKey: "settings.checkServiceStatus") }
    }
    /// OpenCode's plan sets its models' limits and can't be read from anywhere.
    @Published var openCodePlan: OpenCodeProvider.Plan {
        didSet { Self.defaults.set(openCodePlan.rawValue, forKey: "settings.openCodePlan") }
    }

    private init() {
        let d = Self.defaults
        let saved = (d.stringArray(forKey: "settings.providers") ?? []).compactMap(ProviderID.init(rawValue:))
        var enabled = saved.isEmpty ? Set([ProviderID.claude, .codex]) : Set(saved)
        // A service added in an update (OpenCode) turns itself on once, the first time LimitBar sees
        // it, and only if its app is on this Mac; after that it's whatever the toggle says.
        let known = Set((d.stringArray(forKey: "settings.knownProviders") ?? ["claude", "codex"])
            .compactMap(ProviderID.init(rawValue:)))
        for id in ProviderID.allCases where !known.contains(id) && id.appIsInstalled { enabled.insert(id) }
        enabledProviders = enabled
        d.set(enabled.map(\.rawValue), forKey: "settings.providers")
        d.set(ProviderID.allCases.map(\.rawValue), forKey: "settings.knownProviders")
        let minutes = d.integer(forKey: "settings.refreshMinutes")
        refreshMinutes = Self.refreshChoices.contains(minutes) ? minutes : 2
        menuBarNumber = d.string(forKey: "settings.menuBarNumber").flatMap(MenuBarNumber.init(rawValue:)) ?? .highest
        notifyThresholds = d.object(forKey: "settings.notifyThresholds") as? Bool ?? true
        notifyResets = d.object(forKey: "settings.notifyResets") as? Bool ?? true
        notifyFinished = d.object(forKey: "settings.notifyFinished") as? Bool ?? true
        notifyWeekly = d.object(forKey: "settings.notifyWeekly") as? Bool ?? true
        showHistory = d.object(forKey: "settings.showHistory") as? Bool ?? true
        showValue = d.object(forKey: "settings.showValue") as? Bool ?? true
        checkServiceStatus = d.object(forKey: "settings.checkServiceStatus") as? Bool ?? true
        currency = Currency.current
        openCodePlan = OpenCodeProvider.Plan.current
    }

    var visibleProviders: [ProviderID] { ProviderID.allCases.filter(enabledProviders.contains) }

    // MARK: Open at login

    /// Lives in the system (Impostazioni di Sistema › Generali › Elementi login), not in our
    /// defaults, so it's read back from there; see refreshLoginItem().
    @Published private(set) var launchAtLogin = AppSettings.loginItemEnabled

    private static var loginItemEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("LimitBar: login item change failed: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    /// Picks up a change made in System Settings while LimitBar was running.
    func refreshLoginItem() {
        let enabled = Self.loginItemEnabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    var refreshInterval: TimeInterval { TimeInterval(refreshMinutes * 60) }

    /// Keeps at least one service on, so the menu bar item never ends up empty.
    func binding(for id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { self.enabledProviders.contains(id) },
            set: { on in
                if on {
                    self.enabledProviders.insert(id)
                } else if self.enabledProviders.count > 1 {
                    self.enabledProviders.remove(id)
                }
            }
        )
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: UsageStore

    /// "1.0 (12)", as build.sh stamps it; nil outside the app bundle.
    private static let version: String? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return "\(short) (\(build))"
    }()

    var body: some View {
        Form {
            Section(L("General")) {
                Toggle(L("Open at login"), isOn: Binding(get: { settings.launchAtLogin },
                                                      set: { settings.setLaunchAtLogin($0) }))
            }

            // Only for an account LimitBar signed into itself; Claude Code's own stays Claude Code's.
            if store.claudeSignedInHere {
                Section {
                    LabeledContent(L("Claude")) {
                        Button(L("Sign out")) { store.signOutOfClaude() }
                    }
                } header: {
                    Text(L("Account"))
                } footer: {
                    Text(L("LimitBar forgets the Claude sign-in made from the panel. Claude Code doesn't change."))
                }
            }

            Section(L("Services")) {
                ForEach(ProviderID.allCases) { id in
                    Toggle(isOn: settings.binding(for: id)) {
                        HStack(spacing: 8) {
                            Image(nsImage: id.logo).resizable().frame(width: 18, height: 18)
                            Text(id.title)
                        }
                    }
                }
                if settings.enabledProviders.contains(.opencode) {
                    Picker(L("OpenCode plan"), selection: $settings.openCodePlan) {
                        ForEach(OpenCodeProvider.Plan.allCases) { Text($0.title).tag($0) }
                    }
                }
            }

            Section {
                Picker(L("Refresh every"), selection: $settings.refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { Text(L("%d minutes", $0)).tag($0) }
                }
            } header: {
                Text(L("Refresh"))
            } footer: {
                Text(L("Claude is read at most every 5 minutes, to stay within Anthropic's request limit."))
            }

            Section {
                Picker(L("Number shown"), selection: $settings.menuBarNumber) {
                    ForEach(MenuBarNumber.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(L("Menu bar"))
            } footer: {
                Text(L("The number turns orange from 80% and red from 90%. When a limit is used up, it shows how long until it's back."))
            }

            Section {
                Toggle(L("Alert at 80% and 90% of a limit"), isOn: $settings.notifyThresholds)
                Toggle(L("Alert when a used-up limit is available again"), isOn: $settings.notifyResets)
                Toggle(L("Alert when Claude or OpenCode finish a long job"), isOn: $settings.notifyFinished)
                Toggle(L("Weekly summary every Monday"), isOn: $settings.notifyWeekly)
            } header: {
                Text(L("Notifications"))
            } footer: {
                Text(L("A job is long if it lasts at least 2 minutes. There's no alert while you're already using Claude, OpenCode, the terminal or the editor."))
            }

            Section {
                Toggle(L("Show the chart of the last 24 hours"), isOn: $settings.showHistory)
                Toggle(L("Show the value at API prices"), isOn: $settings.showValue)
                Picker(L("Currency"), selection: $settings.currency) {
                    ForEach(Currency.allCases) { Text($0.title).tag($0) }
                }
                Toggle(L("Check the services' status"), isOn: $settings.checkServiceStatus)
            } header: {
                Text(L("Panel"))
            } footer: {
                Text(L("The value is estimated from Claude Code's and OpenCode's local data at public API prices")
                     + (settings.currency == .euro ? L(", in euros at the ECB's daily rate") : "")
                     + L(". Chats on claude.ai aren't included. The services' status comes from Anthropic's and OpenCode's status pages, read every 5 minutes."))
            }

            if let version = Self.version {
                Section(L("About")) {
                    LabeledContent(L("Version"), value: version)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show(store: UsageStore) {
        AppSettings.shared.refreshLoginItem()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: .shared, store: store)))
            window.title = L("LimitBar Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // A menu bar app isn't frontmost on its own; without this the window opens behind others.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
