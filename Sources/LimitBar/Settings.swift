import AppKit
import ServiceManagement
import SwiftUI

/// Which number the menu bar shows next to each service.
enum MenuBarNumber: String, CaseIterable, Identifiable {
    case highest, fiveHour, week

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highest: return "Il limite più usato"
        case .fiveHour: return "5 ore"
        case .week: return "Settimana"
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

    /// "1.0 (12)", as build.sh stamps it; nil outside the app bundle.
    private static let version: String? = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String else { return nil }
        return "\(short) (\(build))"
    }()

    var body: some View {
        Form {
            Section("Generale") {
                Toggle("Apri al login", isOn: Binding(get: { settings.launchAtLogin },
                                                      set: { settings.setLaunchAtLogin($0) }))
            }

            Section("Servizi") {
                ForEach(ProviderID.allCases) { id in
                    Toggle(isOn: settings.binding(for: id)) {
                        HStack(spacing: 8) {
                            Image(nsImage: id.logo).resizable().frame(width: 18, height: 18)
                            Text(id.title)
                        }
                    }
                }
                if settings.enabledProviders.contains(.opencode) {
                    Picker("Piano OpenCode", selection: $settings.openCodePlan) {
                        ForEach(OpenCodeProvider.Plan.allCases) { Text($0.title).tag($0) }
                    }
                }
            }

            Section {
                Picker("Aggiorna ogni", selection: $settings.refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) minuti").tag($0) }
                }
            } header: {
                Text("Aggiornamento")
            } footer: {
                Text("Claude viene letto al massimo ogni 5 minuti, per non superare il limite di richieste di Anthropic.")
            }

            Section {
                Picker("Numero mostrato", selection: $settings.menuBarNumber) {
                    ForEach(MenuBarNumber.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Barra dei menu")
            } footer: {
                Text("Il numero diventa arancione dall'80% e rosso dal 90%. Quando un limite è esaurito, mostra tra quanto torna disponibile.")
            }

            Section {
                Toggle("Avvisa all'80% e al 90% di un limite", isOn: $settings.notifyThresholds)
                Toggle("Avvisa quando un limite esaurito torna disponibile", isOn: $settings.notifyResets)
                Toggle("Avvisa quando Claude o OpenCode finiscono un lavoro lungo", isOn: $settings.notifyFinished)
                Toggle("Riepilogo della settimana ogni lunedì", isOn: $settings.notifyWeekly)
            } header: {
                Text("Notifiche")
            } footer: {
                Text("Un lavoro è lungo se dura almeno 2 minuti. L'avviso non arriva se stai già usando Claude, OpenCode, il terminale o l'editor.")
            }

            Section {
                Toggle("Mostra il grafico delle ultime 24 ore", isOn: $settings.showHistory)
                Toggle("Mostra il valore a prezzi API", isOn: $settings.showValue)
            } header: {
                Text("Pannello")
            } footer: {
                Text("Il valore è stimato sui dati locali di Claude Code e OpenCode, ai prezzi API pubblici convertiti in euro al cambio BCE del giorno. Le chat su claude.ai non sono incluse.")
            }

            if let version = Self.version {
                Section("Informazioni") {
                    LabeledContent("Versione", value: version)
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

    func show() {
        AppSettings.shared.refreshLoginItem()
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: .shared)))
            window.title = "Impostazioni di LimitBar"
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
