import AVKit
import SwiftUI

// MARK: - Historique : ce qui a déjà été téléchargé

struct HistoryView: View {
    @Environment(HistoryStore.self) private var history
    @Environment(\.openURL) private var openURL
    @State private var playing: HistoryItem?
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Group {
                if history.items.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun téléchargement", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Les vidéos que tu télécharges apparaîtront ici.")
                    }
                } else {
                    List {
                        ForEach(sections, id: \.title) { section in
                            Section(section.title) {
                                ForEach(section.items) { item in
                                    Button { open(item) } label: { HistoryRow(item: item) }
                                        .buttonStyle(.plain)
                                        .contextMenu { menu(item) }
                                        .swipeActions {
                                            Button("Supprimer", systemImage: "trash", role: .destructive) { history.remove(item) }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Historique")
            .toolbar {
                if !history.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Tout effacer", systemImage: "trash", role: .destructive) { confirmClear = true }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Options")
                    }
                }
            }
            .confirmationDialog("Effacer tout l’historique ?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Tout effacer", role: .destructive) { history.clear() }
            } message: {
                Text("Les vidéos déjà enregistrées dans Photos y restent.")
            }
            .sheet(item: $playing) { item in
                if let url = history.fileURL(item) { PlayerView(item: item, url: url) }
            }
        }
    }

    private var sections: [(title: String, items: [HistoryItem])] {
        let cal = Calendar.current
        var today: [HistoryItem] = [], week: [HistoryItem] = [], older: [HistoryItem] = []
        for i in history.items {
            if cal.isDateInToday(i.date) { today.append(i) }
            else if let d = cal.dateComponents([.day], from: i.date, to: .now).day, d < 7 { week.append(i) }
            else { older.append(i) }
        }
        return [("Aujourd’hui", today), ("Cette semaine", week), ("Plus ancien", older)].filter { !$0.1.isEmpty }
    }

    private func open(_ item: HistoryItem) {
        if history.fileURL(item) != nil {
            playing = item
        } else if item.assetID != nil, let u = URL(string: "photos-redirect://") {
            openURL(u)
        }
    }

    @ViewBuilder private func menu(_ item: HistoryItem) -> some View {
        if let url = history.fileURL(item) {
            ShareLink(item: url) { Label("Partager", systemImage: "square.and.arrow.up") }
        }
        if item.assetID != nil {
            Button("Ouvrir dans Photos", systemImage: "photo.on.rectangle") {
                if let u = URL(string: "photos-redirect://") { openURL(u) }
            }
        }
        Button("Copier le titre", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.title }
        Divider()
        Button("Supprimer", systemImage: "trash", role: .destructive) { history.remove(item) }
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.thumbnail, cornerRadius: 6)
                .frame(width: 96, height: 54)
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .audio {
                        Image(systemName: "waveform")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [item.quality, Format.size(item.size)]
        parts.append(item.assetID != nil ? "Photos" : "Fichiers")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Lecture d'un fichier gardé dans l'app (audio surtout).
struct PlayerView: View {
    let item: HistoryItem
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if item.kind == .video {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Thumbnail(url: item.thumbnail, cornerRadius: 16)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 280)
                    VideoPlayer(player: player).frame(height: 60)
                }
                Text(item.title).font(.headline).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(20)
            .navigationTitle(item.quality)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
