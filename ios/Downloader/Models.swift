import Foundation
import VideoToolbox

// MARK: - Réponses du PC

struct PCInfo: Decodable {
    let name: String
    let version: Int
    let paired: Bool
}

struct PairResponse: Decodable {
    let token: String
    let name: String
}

struct VideoPreview: Decodable, Equatable {
    let title: String
    let uploader: String?
    let duration: Double?
    let thumbnail: String?
    let platform: String
    let heights: [Int]
    let hasVideo: Bool
}

struct JobState: Decodable, Equatable {
    let id: String
    let status: String
    let stage: String
    let pct: Double?
    let speed: Double?
    let eta: Double?
    let title: String?
    let thumbnail: String?
    let filename: String?
    let size: Int?
    let mime: String?
    let error: String?

    var isFinished: Bool { ["ready", "error", "cancelled"].contains(status) }
}

struct APIError: Decodable { let error: String }

// MARK: - Ce que l'utilisateur choisit

enum MediaKind: String, CaseIterable, Identifiable, Codable {
    case video, audio
    var id: String { rawValue }
    var label: String { self == .video ? "Vidéo" : "Audio" }
}

enum AudioFormat: String, CaseIterable, Identifiable, Codable {
    case m4a, mp3
    var id: String { rawValue }
    var label: String { self == .m4a ? "M4A · qualité d’origine" : "MP3 · 320 kbit/s" }
    var short: String { rawValue.uppercased() }
}

/// 0 = la meilleure qualité disponible.
struct Quality: Hashable, Identifiable {
    let height: Int
    var id: Int { height }

    static let best = Quality(height: 0)

    var label: String {
        switch height {
        case 0: return "Maximale"
        case 4320: return "8K"
        case 2160: return "4K"
        case 1440: return "1440p"
        default: return "\(height)p"
        }
    }

    var detail: String? {
        switch height {
        case 4320: return "4320p"
        case 2160: return "2160p"
        case 1440: return "2K"
        case 1080: return "Full HD"
        case 720: return "HD"
        default: return nil
        }
    }
}

// MARK: - Historique

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var platform: String
    var thumbnail: String?
    var kind: MediaKind
    /// « 4K », « 1080p », « MP3 ».
    var quality: String
    var size: Int
    var date = Date()
    /// Vidéo enregistrée dans Photos.
    var assetID: String?
    /// Fichier gardé dans l'app (audio, ou vidéo si Photos refuse).
    var fileName: String?
}

// MARK: - Capacités de cet iPhone

enum Device {
    /// Les formats vidéo que cet iPhone sait lire sans conversion.
    static var codecs: [String] {
        var c = ["h264", "hevc"]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) { c.append("av1") }
        return c
    }

    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - Mise en forme

enum Format {
    static func size(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double?) -> String? {
        guard let b = bytesPerSecond, b > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) + "/s"
    }

    static func duration(_ seconds: Double?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        f.zeroFormattingBehavior = .pad
        return f.string(from: s)
    }

    static func remaining(_ seconds: Double?) -> String? {
        guard let s = seconds, s > 0, s < 86_400 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: s).map { "encore \($0)" }
    }
}
