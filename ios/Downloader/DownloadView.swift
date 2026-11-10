import SwiftUI

// MARK: - Télécharger : coller un lien, choisir le format, télécharger

struct DownloadView: View {
    @Environment(DownloadModel.self) private var model
    @Environment(PCConnection.self) private var pc
    @State private var showSettings = Demo.sheet == "settings"
    @State private var showPairing = Demo.sheet == "pair"
    @FocusState private var linkFocused: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if !pc.isPaired {
                    connectSection
                }

                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        TextField("Lien de la vidéo", text: $model.link, axis: .vertical)
                            .lineLimit(1...3)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($linkFocused)
                            .onSubmit { linkFocused = false }
                        if !model.link.isEmpty && !model.isBusy {
                            Button {
                                model.clear()
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Effacer le lien")
                        }
                    }
                    if model.link.isEmpty {
                        PasteButton(payloadType: String.self) { texts in
                            if let t = texts.first { Task { @MainActor in model.paste(t) } }
                        }
                        .buttonBorderShape(.capsule)
                        .tint(.accentColor)
                    }
                } footer: {
                    if model.link.isEmpty {
                        Text("YouTube, TikTok, Instagram, X, Facebook, Reddit, Vimeo et plus de mille autres sites.")
                    }
                }
                .disabled(model.isBusy)

                analysisSections
            }
            .navigationTitle("Télécharger")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: pc.online ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(pc.online ? "Ordinateur connecté" : "Ordinateur hors ligne")
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomBar(showPairing: $showPairing)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showPairing) { PairingView() }
            .animation(.smooth(duration: 0.3), value: model.analysis)
            .animation(.smooth(duration: 0.3), value: model.transfer)
        }
    }

    private var connectSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Connecte ton PC", systemImage: "desktopcomputer")
                    .font(.headline)
                Text("Ton PC télécharge la vidéo en pleine qualité, puis l’envoie sur l’iPhone. Ouvre YouTube Downloader sur le PC pour obtenir le code.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            Button("Connecter mon PC") { showPairing = true }
        }
    }

    @ViewBuilder private var analysisSections: some View {
        @Bindable var model = model
        switch model.analysis {
        case .none:
            EmptyView()
        case .loading:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Analyse du lien…").foregroundStyle(.secondary)
                }
            }
        case .failed(let message):
            Section {
                Label {
                    Text(message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if DownloadModel.looksLikeLink(model.link) && pc.isPaired {
                    Button("Réessayer") { model.retryAnalysis() }
                }
            }
        case .ready(let p):
            Section {
                PreviewRow(preview: p)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            Section("Format") {
                if p.hasVideo {
                    Picker("Type", selection: $model.kind) {
                        ForEach(MediaKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if model.kind == .video {
                    Picker("Qualité", selection: $model.quality) {
                        ForEach(model.qualities) { q in
                            if q == .best, let top = p.heights.first {
                                Text("Maximale · \(Quality(height: top).label)").tag(q)
                            } else {
                                Text(q.detail.map { "\(q.label) · \($0)" } ?? q.label).tag(q)
                            }
                        }
                    }
                } else {
                    Picker("Format audio", selection: $model.audio) {
                        ForEach(AudioFormat.allCases) { Text($0.label).tag($0) }
                    }
                }
            }
            .disabled(model.isBusy)
        }
    }
}

// MARK: - Aperçu de la vidéo

struct PreviewRow: View {
    let preview: VideoPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(url: preview.thumbnail, cornerRadius: 12)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let d = Format.duration(preview.duration) {
                        Text(d)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(preview.title)
                    .font(.headline)
                    .lineLimit(2)
                Text([preview.platform, preview.uploader].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Thumbnail: View {
    let url: String?
    var cornerRadius: CGFloat = 8

    var body: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let s = url, let u = URL(string: s) {
                    AsyncImage(url: u, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: "film").foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Image(systemName: "film").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Barre du bas : le bouton, puis la progression

struct BottomBar: View {
    @Environment(DownloadModel.self) private var model
    @Environment(PCConnection.self) private var pc
    @Environment(\.openURL) private var openURL
    @Binding var showPairing: Bool

    var body: some View {
        if let t = model.transfer {
            TransferPanel(transfer: t)
        } else if pc.isPaired {
            Button {
                model.start()
            } label: {
                Label(buttonTitle, systemImage: "arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .primaryButton()
            .controlSize(.large)
            .disabled(model.preview == nil)
        }
    }

    private var buttonTitle: String {
        guard model.preview != nil else { return "Télécharger" }
        if model.kind == .audio { return "Télécharger en \(model.audio.short)" }
        if model.quality == .best, let top = model.preview?.heights.first { return "Télécharger en \(Quality(height: top).label)" }
        return "Télécharger en \(model.quality.label)"
    }
}

struct TransferPanel: View {
    let transfer: DownloadModel.Transfer
    @Environment(DownloadModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = transfer.error {
                failure(error)
            } else if transfer.step == .done {
                done
            } else {
                running
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(cornerRadius: 28)
    }

    private var running: some View {
        Group {
            StepsView(step: transfer.step)
            VStack(alignment: .leading, spacing: 8) {
                Text(transfer.stage)
                    .font(.headline)
                    .contentTransition(.opacity)
                if let p = transfer.progress {
                    ProgressView(value: p)
                } else {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let d = transfer.detail, !d.isEmpty {
                    Text(d)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            Button("Annuler", role: .cancel) { model.cancel() }
                .secondaryButton()
                .frame(maxWidth: .infinity)
        }
    }

    private var done: some View {
        Group {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.stage).font(.headline)
                    if let item = transfer.item {
                        Text("\(item.quality) · \(Format.size(item.size))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                if transfer.savedToPhotos {
                    Button {
                        if let u = URL(string: "photos-redirect://") { openURL(u) }
                    } label: {
                        Label("Ouvrir Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }
                    .secondaryButton()
                }
                Button {
                    model.finish()
                } label: {
                    Text("Nouveau lien").frame(maxWidth: .infinity)
                }
                .primaryButton()
            }
            .controlSize(.large)
        }
    }

    private func failure(_ error: String) -> some View {
        Group {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Le téléchargement a échoué").font(.headline)
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button { model.cancel() } label: { Text("Fermer").frame(maxWidth: .infinity) }
                    .secondaryButton()
                Button { model.cancel(); model.start() } label: { Text("Réessayer").frame(maxWidth: .infinity) }
                    .primaryButton()
            }
            .controlSize(.large)
        }
    }
}

/// PC → iPhone → Photos.
struct StepsView: View {
    let step: DownloadModel.Step

    var body: some View {
        HStack(spacing: 6) {
            item("PC", "desktopcomputer", .pc)
            line(.phone)
            item("iPhone", "iphone", .phone)
            line(.saving)
            item("Photos", "photo.on.rectangle", .saving)
        }
        .font(.caption.weight(.medium))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step == .pc ? "Étape 1 sur 3 : sur le PC" : step == .phone ? "Étape 2 sur 3 : vers l’iPhone" : "Étape 3 sur 3 : enregistrement")
    }

    private func item(_ title: String, _ symbol: String, _ s: DownloadModel.Step) -> some View {
        Label(title, systemImage: step > s ? "checkmark.circle.fill" : symbol)
            .foregroundStyle(step == s ? AnyShapeStyle(.tint) : step > s ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .labelStyle(.titleAndIcon)
    }

    private func line(_ s: DownloadModel.Step) -> some View {
        Capsule()
            .fill(step >= s ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            .frame(height: 1.5)
            .frame(maxWidth: .infinity)
    }
}
