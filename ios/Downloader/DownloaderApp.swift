import SwiftUI

@main
struct DownloaderApp: App {
    @State private var pc: PCConnection
    @State private var history: HistoryStore
    @State private var model: DownloadModel
    @State private var browser = PCBrowser()

    init() {
        let pc = PCConnection()
        let history = HistoryStore()
        _pc = State(initialValue: pc)
        _history = State(initialValue: history)
        _model = State(initialValue: DownloadModel(pc: pc, history: history))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(pc)
                .environment(history)
                .environment(model)
                .environment(browser)
        }
    }
}

/// Deux onglets : télécharger, et ce qui a déjà été téléchargé.
struct RootView: View {
    @Environment(PCConnection.self) private var pc
    @Environment(HistoryStore.self) private var history
    @Environment(DownloadModel.self) private var model
    @Environment(PCBrowser.self) private var browser
    @Environment(\.scenePhase) private var phase
    @State private var tab = Demo.tab ?? "download"

    var body: some View {
        TabView(selection: $tab) {
            DownloadView()
                .tabItem { Label("Télécharger", systemImage: "arrow.down.circle") }
                .tag("download")
            HistoryView()
                .tabItem { Label("Historique", systemImage: "clock") }
                .tag("history")
        }
        .task { await setup() }
        .onChange(of: phase) { _, new in
            if new == .active { Task { await reconnect() } }
        }
    }

    private func setup() async {
        if let state = Demo.state {
            pc.demo()
            history.demo()
            model.demo(state)
            return
        }
        browser.start()
        await reconnect()
    }

    /// Si le PC a changé d'adresse (redémarrage, autre Wi-Fi), on le retrouve par son nom.
    private func reconnect() async {
        guard Demo.state == nil, pc.isPaired else { return }
        if await pc.check() { return }
        try? await Task.sleep(for: .seconds(2))
        guard let name = pc.name, let match = browser.found.first(where: { $0.name.hasPrefix(name.prefix(12)) }) else { return }
        if let address = await PCBrowser.resolve(match.endpoint) {
            pc.update(address: address)
            await pc.check()
        }
    }
}

/// Réglages de démonstration, utilisés seulement pour les captures d'écran automatiques.
enum Demo {
    private static func arg(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    static var state: String? { arg("-demo") }
    static var tab: String? { arg("-tab") }
    static var sheet: String? { arg("-sheet") }
}
