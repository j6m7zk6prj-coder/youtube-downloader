import SwiftUI

// MARK: - Réglages : l'ordinateur connecté

struct SettingsView: View {
    @Environment(PCConnection.self) private var pc
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var confirmForget = false
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if pc.isPaired {
                        LabeledContent("Nom", value: pc.name ?? "PC")
                        LabeledContent("État") {
                            HStack(spacing: 6) {
                                Circle().fill(pc.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                                Text(checking ? "Vérification…" : pc.online ? "Connecté" : "Hors ligne")
                            }
                        }
                        LabeledContent("Adresse", value: (pc.address ?? "").replacingOccurrences(of: "http://", with: ""))
                        Button("Vérifier la connexion") {
                            Task { checking = true; await pc.check(); checking = false }
                        }
                        Button("Changer d’ordinateur") { pairing = true }
                        Button("Oublier cet ordinateur", role: .destructive) { confirmForget = true }
                    } else {
                        Button("Connecter mon PC") { pairing = true }
                    }
                } header: {
                    Text("Ordinateur")
                } footer: {
                    if pc.isPaired && !pc.online {
                        Text("Allume le PC, ouvre YouTube Downloader et vérifie que l’iPhone est sur le même Wi-Fi.")
                    }
                }

                Section {
                    LabeledContent("Lus sans conversion", value: Device.codecs.map(codecName).joined(separator: ", "))
                } header: {
                    Text("Cet iPhone")
                } footer: {
                    Text("Si la meilleure qualité n’existe que dans un autre format, ton PC la convertit avant l’envoi pour qu’elle se lise dans Photos.")
                }

                Section("Fonctionnement") {
                    step(1, "Tu colles un lien ici.")
                    step(2, "Ton PC télécharge la vidéo en pleine qualité.")
                    step(3, "L’iPhone la récupère sur le Wi-Fi et l’enregistre dans Photos.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .sheet(isPresented: $pairing) { PairingView() }
            .confirmationDialog("Oublier \(pc.name ?? "ce PC") ?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Oublier", role: .destructive) { pc.forget() }
            } message: {
                Text("Il faudra entrer un nouveau code pour le reconnecter.")
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "\(n).circle.fill").foregroundStyle(.tint)
            Text(text)
        }
    }

    private func codecName(_ c: String) -> String {
        switch c {
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        default: return c
        }
    }
}

// MARK: - Connecter le PC : le choisir sur le Wi-Fi, puis entrer le code

struct PairingView: View {
    @Environment(PCConnection.self) private var pc
    @Environment(PCBrowser.self) private var browser
    @Environment(\.dismiss) private var dismiss
    @State private var selected: FoundPC?
    @State private var manual = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case manual, code }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if browser.found.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Recherche sur le Wi-Fi…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(found) { p in
                        Button {
                            selected = p
                            manual = ""
                            focus = .code
                        } label: {
                            HStack {
                                Label(p.name, systemImage: "desktopcomputer")
                                    .foregroundStyle(.primary)
                                Spacer()
                                if selected == p { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                } header: {
                    Text("Ordinateurs trouvés")
                } footer: {
                    Text("Ouvre YouTube Downloader sur ton PC. L’iPhone et le PC doivent être sur le même Wi-Fi.")
                }

                Section {
                    TextField("192.168.1.20:8765", text: $manual)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .manual)
                        .onChange(of: manual) { _, v in if !v.isEmpty { selected = nil } }
                } header: {
                    Text("Ou entre l’adresse")
                } footer: {
                    Text("Elle est affichée sous le code, dans le panneau « iPhone » du logiciel PC.")
                }

                Section {
                    TextField("123 456", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.title2.monospacedDigit().weight(.semibold))
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, v in
                            let digits = String(v.filter(\.isNumber).prefix(6))
                            if digits != v.filter(\.isNumber) || v.count > 7 { code = digits }
                        }
                } header: {
                    Text("Code affiché sur le PC")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connexion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Connecter") { Task { await connect() } }
                            .disabled(!canConnect)
                    }
                }
            }
            .onAppear {
                browser.start()
                if Demo.state != nil { code = "482913" }
            }
        }
    }

    private var found: [FoundPC] {
        if Demo.state != nil {
            return [FoundPC(name: "PC-MOH", endpoint: .service(name: "PC-MOH", type: "_ytdl._tcp", domain: "local.", interface: nil))]
        }
        return browser.found
    }

    private var canConnect: Bool {
        code.filter(\.isNumber).count == 6 && (selected != nil || !manual.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        var address = manual
        if let s = selected {
            guard let a = await PCBrowser.resolve(s.endpoint) else {
                error = "Impossible de joindre \(s.name). Entre son adresse à la main."
                return
            }
            address = a
        }
        do {
            try await pc.pair(address: address, code: code)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case DownloaderError.server = error { self.error = "Code incorrect. Vérifie le code affiché sur le PC." }
        }
    }
}
