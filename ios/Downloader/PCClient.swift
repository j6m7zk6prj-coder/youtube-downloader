import Foundation
import Network
import Observation

// MARK: - La connexion au PC

@MainActor
@Observable
final class PCConnection {
    /// « http://192.168.1.20:8765 ».
    private(set) var address: String?
    private(set) var name: String?
    private(set) var token: String?
    /// Le PC répond (vérifié régulièrement).
    private(set) var online = false

    var isPaired: Bool { address != nil && token != nil }

    init() {
        let d = UserDefaults.standard
        address = d.string(forKey: "pc.address")
        name = d.string(forKey: "pc.name")
        token = d.string(forKey: "pc.token")
    }

    func pair(address: String, code: String) async throws {
        let base = Self.normalize(address)
        let body = try JSONEncoder().encode(["code": code.filter(\.isNumber)])
        let r: PairResponse = try await request(base, "/pair", method: "POST", body: body, token: nil)
        self.address = base
        self.name = r.name
        self.token = r.token
        online = true
        let d = UserDefaults.standard
        d.set(base, forKey: "pc.address")
        d.set(r.name, forKey: "pc.name")
        d.set(r.token, forKey: "pc.token")
    }

    /// Pour les captures d'écran automatiques.
    func demo() {
        address = "http://192.168.1.20:8765"; name = "PC-MOH"; token = "demo"; online = true
    }

    func forget() {
        address = nil; name = nil; token = nil; online = false
        for k in ["pc.address", "pc.name", "pc.token"] { UserDefaults.standard.removeObject(forKey: k) }
    }

    /// L'adresse a peut-être changé (le PC a redémarré) : on la met à jour sans redemander le code.
    func update(address: String) {
        let base = Self.normalize(address)
        self.address = base
        UserDefaults.standard.set(base, forKey: "pc.address")
    }

    @discardableResult
    func check() async -> Bool {
        guard let address else { online = false; return false }
        do {
            let info: PCInfo = try await request(address, "/info", method: "GET", body: nil, token: token, timeout: 4)
            online = info.paired
            if !info.paired { token = nil; UserDefaults.standard.removeObject(forKey: "pc.token") }
        } catch {
            online = false
        }
        return online
    }

    func analyze(_ url: String) async throws -> VideoPreview {
        try await call("/analyze", method: "POST", body: ["url": url], timeout: 90)
    }

    func start(url: String, kind: MediaKind, quality: Int, audio: AudioFormat) async throws -> JobState {
        struct Body: Encodable { let url: String; let mode: String; let quality: Int; let audio: String; let codecs: [String] }
        let body = Body(url: url, mode: kind.rawValue, quality: quality, audio: audio.rawValue, codecs: Device.codecs)
        return try await call("/jobs", method: "POST", body: body, timeout: 30)
    }

    func job(_ id: String) async throws -> JobState {
        try await call("/jobs/\(id)", method: "GET", body: Optional<[String: String]>.none, timeout: 15)
    }

    func cancel(_ id: String) async {
        let _: [String: Bool]? = try? await call("/jobs/\(id)/cancel", method: "POST", body: [String: String](), timeout: 10)
    }

    func delete(_ id: String) async {
        let _: [String: Bool]? = try? await call("/jobs/\(id)", method: "DELETE", body: Optional<[String: String]>.none, timeout: 10)
    }

    func fileRequest(_ id: String) -> URLRequest? {
        guard let address, let url = URL(string: address + "/jobs/\(id)/file") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 120)
        r.setValue(token, forHTTPHeaderField: "X-Token")
        return r
    }

    // MARK: Réseau

    private func call<T: Decodable, B: Encodable>(_ path: String, method: String, body: B?, timeout: TimeInterval) async throws -> T {
        guard let address else { throw DownloaderError.notPaired }
        let data = try body.map { try JSONEncoder().encode($0) }
        do {
            return try await request(address, path, method: method, body: data, token: token, timeout: timeout)
        } catch let e as DownloaderError {
            if case .unauthorized = e { token = nil; online = false; UserDefaults.standard.removeObject(forKey: "pc.token") }
            throw e
        }
    }

    private func request<T: Decodable>(_ base: String, _ path: String, method: String, body: Data?, token: String?, timeout: TimeInterval = 20) async throws -> T {
        guard let url = URL(string: base + path) else { throw DownloaderError.badAddress }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { r.setValue(token, forHTTPHeaderField: "X-Token") }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: r)
        } catch {
            online = false
            throw DownloaderError.unreachable
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { throw DownloaderError.unauthorized }
        guard (200..<300).contains(code) else {
            let msg = (try? JSONDecoder().decode(APIError.self, from: data))?.error
            throw DownloaderError.server(msg ?? "Le PC a répondu par une erreur (\(code)).")
        }
        online = true
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func normalize(_ s: String) -> String {
        var a = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.hasSuffix("/") { a.removeLast() }
        if !a.lowercased().hasPrefix("http") { a = "http://" + a }
        if let u = URL(string: a), u.port == nil { a += ":8765" }
        return a
    }
}

enum DownloaderError: LocalizedError {
    case notPaired, unreachable, unauthorized, badAddress, server(String), photos(String)

    var errorDescription: String? {
        switch self {
        case .notPaired: return "Connecte d’abord ton PC."
        case .unreachable: return "Le PC ne répond pas. Vérifie qu’il est allumé, que YouTube Downloader est ouvert et que l’iPhone est sur le même Wi-Fi."
        case .unauthorized: return "Le PC demande un nouveau code. Entre celui affiché sur le PC."
        case .badAddress: return "Adresse du PC invalide."
        case .server(let m): return m
        case .photos(let m): return m
        }
    }
}

// MARK: - Trouver le PC sur le Wi-Fi (Bonjour)

struct FoundPC: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

@MainActor
@Observable
final class PCBrowser {
    private(set) var found: [FoundPC] = []
    private(set) var searching = false
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: "_ytdl._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> FoundPC? in
                if case let .service(name, _, _, _) = r.endpoint { return FoundPC(name: name, endpoint: r.endpoint) }
                return nil
            }
            Task { @MainActor in self?.found = list.sorted { $0.name < $1.name } }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.searching = true
                case .failed, .cancelled: self?.searching = false
                default: break
                }
            }
        }
        b.start(queue: .main)
        browser = b
        searching = true
    }

    func stop() {
        browser?.cancel()
        browser = nil
        searching = false
    }

    /// Transforme un PC trouvé en adresse « http://ip:port ».
    nonisolated static func resolve(_ endpoint: NWEndpoint) async -> String? {
        await withCheckedContinuation { cont in
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let conn = NWConnection(to: endpoint, using: params)
            let box = Once()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var result: String?
                    if case let .hostPort(host, port) = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let i = h.firstIndex(of: "%") { h = String(h[..<i]) }
                        if h.contains(":") { h = "[\(h)]" }
                        result = "http://\(h):\(port.rawValue)"
                    }
                    conn.cancel()
                    box.run { cont.resume(returning: result) }
                case .failed, .cancelled:
                    box.run { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                conn.cancel()
                box.run { cont.resume(returning: nil) }
            }
        }
    }
}

/// Exécute une seule fois (pour ne reprendre la continuation qu'une fois).
final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}
