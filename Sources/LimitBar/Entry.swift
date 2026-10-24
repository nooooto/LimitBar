import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            dump()
        } else if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            render(to: args[i + 1], dark: args.contains("--dark"))
        } else {
            runApp()
        }
    }

    /// `LimitBar --dump` prints what the app would show (no tokens), handy for debugging.
    private static func dump() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let providers: [(String, @Sendable () async throws -> ProviderSnapshot)] = [
                ("claude", { try await ClaudeProvider.fetch() }), ("codex", { try await CodexProvider.fetch() }),
                ("codex-api", { try await CodexProvider.fetchFromAPI() }),
            ]
            for (name, fetch) in providers {
                do {
                    let data = try encoder.encode(try await fetch())
                    print("\(name): \(String(decoding: data, as: UTF8.self))")
                } catch {
                    print("\(name): error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
                }
            }
            done.signal()
        }
        done.wait()
    }

    /// `LimitBar --render out.png [--dark]` writes the panel as an image, for checking the layout.
    /// Uses the cached data only, so it never spends a request on the usage endpoints.
    private static func render(to path: String, dark: Bool) {
        Task { @MainActor in
            let store = UsageStore()
            // The API-price value is read from the logs in the background; give it a moment.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let view = PanelView(store: store)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let cg = renderer.cgImage,
               let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
        RunLoop.main.run()
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller = StatusController()
            Notifier.setUp()
        }
    }
}

private func runApp() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
