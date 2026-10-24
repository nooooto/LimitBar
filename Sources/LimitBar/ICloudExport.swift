import Foundation

/// Copies the current limits to iCloud Drive so an iPhone widget can show them.
///
/// - `iCloud Drive/LimitBar/limitbar.json` always.
/// - Scriptable's iCloud folder, once that app is installed on a device with the same iCloud
///   account: there the data sits next to the widget script, which is installed too.
enum ICloudExport {
    private static let mobileDocuments = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents")
    private static let driveFolder = mobileDocuments.appendingPathComponent("com~apple~CloudDocs/LimitBar")
    private static let scriptableFolder = mobileDocuments.appendingPathComponent("iCloud~dk~simonbs~Scriptable/Documents")

    private static let dataFile = "limitbar.json"
    private static let scriptFile = "LimitBar.js"
    /// First line of the shipped script; a file starting with it is ours to update.
    private static let scriptMarker = "// LimitBar widget"

    private static var lastWritten: Data?

    private struct Payload: Encodable {
        let version = 1
        let updatedAt: Date?
        let providers: [Provider]

        struct Provider: Encodable {
            let id: String
            let name: String
            let plan: String?
            let updatedAt: Date?
            let source: String?
            let fiveHour: UsageWindow?
            let week: UsageWindow?
            let extras: [ExtraLimit]
            let error: String?
        }
    }

    /// Only the services turned on in the settings go to the widget.
    @MainActor
    static func write(_ states: [ProviderID: ProviderState]) {
        let providers = AppSettings.shared.visibleProviders.map { id -> Payload.Provider in
            let state = states[id] ?? ProviderState()
            let snapshot = state.snapshot
            return Payload.Provider(
                id: id.rawValue, name: id.title, plan: snapshot?.plan, updatedAt: snapshot?.updatedAt,
                source: snapshot?.source, fiveHour: snapshot?.fiveHour, week: snapshot?.week,
                extras: snapshot?.extras ?? [], error: state.error
            )
        }
        // The newest reading rather than "now", so an unchanged state encodes to the same bytes.
        let payload = Payload(updatedAt: providers.compactMap(\.updatedAt).max(), providers: providers)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload), data != lastWritten else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: driveFolder, withIntermediateDirectories: true)
        var folders = [driveFolder]
        if fm.fileExists(atPath: scriptableFolder.path) { folders.append(scriptableFolder) }
        for folder in folders {
            try? data.write(to: folder.appendingPathComponent(dataFile), options: .atomic)
            installScript(in: folder)
        }
        lastWritten = data
    }

    /// Puts the bundled widget script in `folder`, unless the user has replaced it with their own.
    private static func installScript(in folder: URL) {
        guard let bundled = Bundle.main.url(forResource: "LimitBar", withExtension: "js"),
              let script = try? String(contentsOf: bundled, encoding: .utf8) else { return }
        let target = folder.appendingPathComponent(scriptFile)
        if let existing = try? String(contentsOf: target, encoding: .utf8) {
            guard existing.hasPrefix(scriptMarker), existing != script else { return }
        }
        try? script.write(to: target, atomically: true, encoding: .utf8)
    }
}
