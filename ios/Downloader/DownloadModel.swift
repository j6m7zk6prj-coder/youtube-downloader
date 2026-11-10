import Foundation
import Observation
import Photos
import UIKit

// MARK: - Un téléchargement : analyse du lien, téléchargement sur le PC, transfert, Photos

@MainActor
@Observable
final class DownloadModel {
    enum Analysis: Equatable {
        case none
        case loading
        case ready(VideoPreview)
        case failed(String)
    }

    enum Step: Int, Comparable {
        case pc, phone, saving, done
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    struct Transfer: Equatable {
        var step: Step = .pc
        var stage = "Envoi au PC…"
        var progress: Double?
        var detail: String?
        var error: String?
        var item: HistoryItem?
        var savedToPhotos = false
    }

    var link = "" {
        didSet { if link != oldValue { scheduleAnalysis() } }
    }
    private(set) var analysis: Analysis = .none
    var kind: MediaKind = .video
    var quality: Quality = .best
    var audio: AudioFormat = .m4a
    private(set) var transfer: Transfer?

    var isBusy: Bool { transfer != nil && transfer?.step != .done && transfer?.error == nil }

    var preview: VideoPreview? {
        if case let .ready(p) = analysis { return p }
        return nil
    }

    /// Les qualités proposées pour ce lien.
    var qualities: [Quality] {
        [.best] + (preview?.heights ?? []).filter { $0 >= 144 }.map { Quality(height: $0) }
    }

    let pc: PCConnection
    let history: HistoryStore
    private var analysisTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var jobID: String?

    init(pc: PCConnection, history: HistoryStore) {
        self.pc = pc
        self.history = history
        let d = UserDefaults.standard
        if let k = d.string(forKey: "pref.kind").flatMap(MediaKind.init) { kind = k }
        if let a = d.string(forKey: "pref.audio").flatMap(AudioFormat.init) { audio = a }
    }

    static func looksLikeLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let host = u.host, u.scheme?.hasPrefix("http") == true else { return false }
        return host.contains(".")
    }

    /// Prend le premier lien trouvé dans un texte collé (« Regarde ça https://… »).
    static func extractLink(_ s: String) -> String {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(s.startIndex..., in: s)
        if let m = detector?.firstMatch(in: s, range: range), let url = m.url { return url.absoluteString }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func paste(_ text: String) {
        link = Self.extractLink(text)
    }

    func clear() {
        link = ""
        analysis = .none
        transfer = nil
        quality = .best
    }

    // MARK: Analyse

    private func scheduleAnalysis() {
        analysisTask?.cancel()
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeLink(url) else {
            analysis = url.isEmpty ? .none : .failed("Ce n’est pas un lien valide.")
            return
        }
        guard pc.isPaired else { analysis = .failed(DownloaderError.notPaired.localizedDescription); return }
        analysis = .loading
        analysisTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let p = try await pc.analyze(url)
                guard !Task.isCancelled else { return }
                analysis = .ready(p)
                if quality != .best, !p.heights.contains(quality.height) { quality = .best }
                if !p.hasVideo { kind = .audio }
            } catch {
                guard !Task.isCancelled else { return }
                analysis = .failed(error.localizedDescription)
            }
        }
    }

    func retryAnalysis() { scheduleAnalysis() }

    // MARK: Téléchargement

    func start() {
        guard !isBusy else { return }
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeLink(url) else { return }
        UserDefaults.standard.set(kind.rawValue, forKey: "pref.kind")
        UserDefaults.standard.set(audio.rawValue, forKey: "pref.audio")
        transfer = Transfer()
        let preview = self.preview
        let kind = self.kind, quality = self.quality, audio = self.audio
        runTask = Task { await run(url: url, preview: preview, kind: kind, quality: quality, audio: audio) }
    }

    func cancel() {
        runTask?.cancel()
        if let id = jobID { Task { await pc.cancel(id); await pc.delete(id) } }
        jobID = nil
        transfer = nil
    }

    func finish() {
        clear()
    }

    private func run(url: String, preview: VideoPreview?, kind: MediaKind, quality: Quality, audio: AudioFormat) async {
        let background = UIApplication.shared.beginBackgroundTask(withName: "download")
        defer { UIApplication.shared.endBackgroundTask(background) }
        do {
            // 1. Le PC télécharge.
            var job = try await pc.start(url: url, kind: kind, quality: quality.height, audio: audio)
            jobID = job.id
            while !job.isFinished {
                try Task.checkCancellation()
                update(job)
                try await Task.sleep(for: .milliseconds(700))
                job = try await pc.job(job.id)
            }
            if job.status == "error" { throw DownloaderError.server(job.error ?? "Le téléchargement a échoué.") }
            if job.status == "cancelled" { transfer = nil; return }

            // 2. L'iPhone récupère le fichier.
            transfer?.step = .phone
            transfer?.stage = "Transfert vers l’iPhone"
            transfer?.progress = 0
            transfer?.detail = Format.size(job.size)
            guard let request = pc.fileRequest(job.id) else { throw DownloaderError.notPaired }
            let name = job.filename ?? "video.mp4"
            let expected = Int64(job.size ?? 0)
            let local = try await FileFetcher.fetch(request, name: name) { [weak self] done, total in
                Task { @MainActor in
                    guard let self, self.transfer?.step == .phone else { return }
                    let t = total > 0 ? total : expected
                    self.transfer?.progress = t > 0 ? Double(done) / Double(t) : nil
                    self.transfer?.detail = t > 0 ? "\(Format.size(Int(done))) sur \(Format.size(Int(t)))" : Format.size(Int(done))
                }
            }
            try Task.checkCancellation()
            await pc.delete(job.id)
            jobID = nil

            // 3. Photos (vidéo) ou dossier de l'app (audio).
            transfer?.step = .saving
            transfer?.stage = kind == .video ? "Enregistrement dans Photos" : "Enregistrement"
            transfer?.progress = nil
            transfer?.detail = nil
            var item = HistoryItem(
                title: job.title ?? preview?.title ?? name,
                platform: preview?.platform ?? "",
                thumbnail: job.thumbnail ?? preview?.thumbnail,
                kind: kind,
                quality: kind == .audio ? audio.short : label(for: quality, preview: preview),
                size: job.size ?? 0
            )
            var saved = false
            if kind == .video {
                do {
                    item.assetID = try await PhotoSaver.save(video: local)
                    try? FileManager.default.removeItem(at: local)
                    saved = true
                } catch {
                    // Photos refuse : on garde le fichier dans l'app (visible dans Fichiers).
                    item.fileName = try keep(local)
                    transfer?.error = nil
                }
            } else {
                item.fileName = try keep(local)
            }
            history.add(item)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            transfer?.step = .done
            transfer?.stage = saved ? "Enregistrée dans Photos" : (kind == .audio ? "Enregistré dans Fichiers" : "Enregistrée dans Fichiers")
            transfer?.item = item
            transfer?.savedToPhotos = saved
        } catch is CancellationError {
            transfer = nil
        } catch {
            if let id = jobID { await pc.delete(id); jobID = nil }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            transfer?.error = error.localizedDescription
        }
    }

    private func update(_ job: JobState) {
        transfer?.step = .pc
        transfer?.stage = job.stage
        transfer?.progress = job.pct.map { $0 / 100 }
        transfer?.detail = [job.pct.map { "\(Int($0)) %" }, Format.speed(job.speed), Format.remaining(job.eta)]
            .compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func label(for q: Quality, preview: VideoPreview?) -> String {
        if q == .best, let top = preview?.heights.first { return Quality(height: top).label }
        return q.label
    }

    /// Range le fichier dans le dossier de l'app (visible dans Fichiers > Sur mon iPhone > Downloader).
    private func keep(_ url: URL) throws -> String {
        var dest = Device.documents.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = url.deletingPathExtension().lastPathComponent
            dest = Device.documents.appendingPathComponent("\(base) \(n).\(url.pathExtension)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: dest)
        return dest.lastPathComponent
    }

    // MARK: Démo (captures d'écran)

    func demo(_ state: String) {
        let p = VideoPreview(title: "Big Buck Bunny 60fps 4K – Official Blender Foundation Short Film",
                             uploader: "Blender", duration: 634,
                             thumbnail: "https://i.ytimg.com/vi/aqz-KE-bpKQ/maxresdefault.jpg",
                             platform: "YouTube", heights: [2160, 1440, 1080, 720, 480, 360], hasVideo: true)
        link = ""
        analysisTask?.cancel()
        switch state {
        case "preview":
            link = "https://youtu.be/aqz-KE-bpKQ"; analysisTask?.cancel(); analysis = .ready(p)
        case "progress":
            link = "https://youtu.be/aqz-KE-bpKQ"; analysisTask?.cancel(); analysis = .ready(p)
            transfer = Transfer(step: .pc, stage: "Téléchargement sur le PC", progress: 0.46,
                                detail: "46 %  ·  18,4 Mo/s  ·  encore 32 s")
        case "transfer":
            link = "https://youtu.be/aqz-KE-bpKQ"; analysisTask?.cancel(); analysis = .ready(p)
            transfer = Transfer(step: .phone, stage: "Transfert vers l’iPhone", progress: 0.72, detail: "612 Mo sur 850 Mo")
        case "done":
            link = "https://youtu.be/aqz-KE-bpKQ"; analysisTask?.cancel(); analysis = .ready(p)
            transfer = Transfer(step: .done, stage: "Enregistrée dans Photos", progress: 1,
                                item: HistoryItem(title: p.title, platform: "YouTube", thumbnail: p.thumbnail, kind: .video, quality: "4K", size: 891_000_000),
                                savedToPhotos: true)
        case "error":
            link = "https://www.instagram.com/reel/abc"; analysisTask?.cancel()
            analysis = .failed("Ce site demande d’être connecté pour cette vidéo.")
        default:
            analysis = .none
        }
    }
}

// MARK: - Téléchargement d'un fichier avec progression

final class FileFetcher: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Int64, Int64) -> Void
    private let name: String
    private var session: URLSession?

    private init(name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.name = name
        self.progress = progress
    }

    static func fetch(_ request: URLRequest, name: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let f = FileFetcher(name: name, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                f.continuation = cont
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 120
                config.timeoutIntervalForResource = 6 * 3600
                let s = URLSession(configuration: config, delegate: f, delegateQueue: nil)
                f.session = s
                s.downloadTask(with: request).resume()
            }
        } onCancel: {
            f.session?.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            finish(.failure(DownloaderError.server("Le PC n’a pas pu envoyer le fichier (\(code)).")))
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "-")
            let dest = dir.appendingPathComponent(safe.isEmpty ? "video.mp4" : safe)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let cancelled = (error as NSError).code == NSURLErrorCancelled
            finish(.failure(cancelled ? CancellationError() : DownloaderError.unreachable))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}

// MARK: - Photos

enum PhotoSaver {
    static func save(video url: URL) async throws -> String? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw DownloaderError.photos("Autorise l’accès à Photos dans Réglages > Downloader.")
        }
        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            req.addResource(with: .video, fileURL: url, options: options)
            id = req.placeholderForCreatedAsset?.localIdentifier
        }
        return id
    }
}

// MARK: - Historique

@MainActor
@Observable
final class HistoryStore {
    private(set) var items: [HistoryItem] = []

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.url), let list = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = list
        }
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        save()
    }

    func remove(_ item: HistoryItem) {
        if let f = item.fileName { try? FileManager.default.removeItem(at: Device.documents.appendingPathComponent(f)) }
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        for i in items { if let f = i.fileName { try? FileManager.default.removeItem(at: Device.documents.appendingPathComponent(f)) } }
        items = []
        save()
    }

    func fileURL(_ item: HistoryItem) -> URL? {
        guard let f = item.fileName else { return nil }
        let u = Device.documents.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: Self.url, options: .atomic) }
    }

    func demo() {
        let now = Date()
        items = [
            HistoryItem(title: "Big Buck Bunny 60fps 4K – Official Blender Foundation Short Film", platform: "YouTube",
                        thumbnail: "https://i.ytimg.com/vi/aqz-KE-bpKQ/maxresdefault.jpg", kind: .video, quality: "4K", size: 891_000_000, date: now),
            HistoryItem(title: "Sintel – Open Movie by Blender Foundation", platform: "YouTube",
                        thumbnail: "https://i.ytimg.com/vi/eRsGyueVLvQ/hqdefault.jpg", kind: .video, quality: "1080p", size: 312_000_000, date: now.addingTimeInterval(-3_600)),
            HistoryItem(title: "Tears of Steel – Blender Open Movie", platform: "YouTube",
                        thumbnail: "https://i.ytimg.com/vi/R6MlUcmOul8/hqdefault.jpg", kind: .audio, quality: "M4A", size: 11_800_000, date: now.addingTimeInterval(-86_400)),
            HistoryItem(title: "Cosmos Laundromat – First Cycle", platform: "YouTube",
                        thumbnail: "https://i.ytimg.com/vi/Y-rmzh0PI3c/hqdefault.jpg", kind: .video, quality: "1440p", size: 540_000_000, date: now.addingTimeInterval(-3 * 86_400)),
        ]
    }
}
