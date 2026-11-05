import CryptoKit
import Foundation

public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case int(Int), string(String)
    public var intValue: Int? { if case .int(let v) = self { v } else { nil } }
    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .int(let v): try c.encode(v); case .string(let v): try c.encode(v) }
    }
}

/// A monitor setting exposed by Samsung IP Control. Every case was checked against an Odyssey G80SD.
public enum Setting: String, CaseIterable, Codable, Sendable {
    case backlight, volume, mute, contrast, sharpness, color, tint, shadowDetail
    case colorTone, soundMode, gameMode, contrastEnhancer, inputSource, power, pictureMode

    public var method: String {
        switch self {
        case .backlight: "backlightControl"
        case .volume: "directVolumeControl"
        case .mute: "muteControl"
        case .contrast: "contrastControl"
        case .sharpness: "sharpnessControl"
        case .color: "colorControl"
        case .tint: "tintControl"
        case .shadowDetail: "brightnessControl"
        case .colorTone: "colorToneControl"
        case .soundMode: "soundModeControl"
        case .gameMode: "gameModeControl"
        case .contrastEnhancer: "contrastEnhancerControl"
        case .inputSource: "inputSourceControl"
        case .power: "powerControl"
        case .pictureMode: "pictureModeControl"
        }
    }
    public var key: String {
        switch self {
        case .shadowDetail: "brightness"
        default: rawValue
        }
    }
    public var range: ClosedRange<Int>? {
        switch self {
        case .backlight, .contrast, .color: 0...50
        case .volume: 0...100
        case .sharpness: 0...20
        case .tint: -15...15
        case .shadowDetail: -5...5
        default: nil
        }
    }
}

public enum IPControlError: Error, Equatable, Sendable {
    case unauthorized
    case unsupported
    case rejected(String)
    case transport(String)
    case certificateChanged
    case badResponse
}

public enum RPC {
    public static func body(method: String, token: String?, params: [String: JSONValue] = [:]) throws -> Data {
        struct Envelope: Encodable {
            let jsonrpc = "2.0", id = 1, method: String
            let params: [String: JSONValue]?
        }
        var all = params
        if let token { all["AccessToken"] = .string(token) }
        return try JSONEncoder().encode(Envelope(method: method, params: all.isEmpty ? nil : all))
    }

    /// Firmware answers a bad token with a bare `{code:-32700}` outside the JSON-RPC envelope.
    public static func parse(_ data: Data) throws -> [String: JSONValue] {
        struct Failure: Decodable { let code: Int; let message: String? }
        struct Envelope: Decodable {
            let result: [String: JSONValue]?
            let error: Failure?
            let code: Int?
            let message: String?
        }
        guard let e = try? JSONDecoder().decode(Envelope.self, from: data) else { throw IPControlError.badResponse }
        if let result = e.result { return result }
        let code = e.error?.code ?? e.code
        let message = e.error?.message ?? e.message ?? "Unknown error"
        switch code {
        case -32700, -32010: throw IPControlError.unauthorized
        case -32601, -32001: throw IPControlError.unsupported
        case .some: throw IPControlError.rejected(message)
        case nil: throw IPControlError.badResponse
        }
    }
}

public enum Bonjour {
    /// `se` looks like `http://192.0.2.10:8001/api/v2/`.
    public static func host(fromServiceEndpoint se: String?) -> String? {
        se.flatMap { URLComponents(string: $0)?.host }
    }
    public static func friendlyName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
}

final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _expected: String?
    nonisolated(unsafe) private var _observed: String?
    init(expected: String?) { _expected = expected }
    var observed: String? { lock.withLock { _observed } }
    var mismatch: Bool { lock.withLock { _expected != nil && _observed != nil && _expected != _observed } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let print = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
        let allowed: Bool = lock.withLock {
            _observed = print
            return _expected == nil || _expected == print
        }
        return allowed ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}

/// Talks to one monitor. Calls run strictly one at a time, because the monitor resets overlapping connections.
public actor IPControlClient {
    public nonisolated let host: String
    private let port: Int
    private var token: String?
    private let delegate: PinningDelegate
    private let session: URLSession
    private var tail: Task<Void, Never>?

    public init(host: String, port: Int = 1516, token: String?, pin: String?) {
        self.host = host
        self.port = port
        self.token = token
        delegate = PinningDelegate(expected: pin)
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public var certificateFingerprint: String? { delegate.observed }

    public func read(_ s: Setting, timeout: TimeInterval = 5) async throws -> JSONValue? {
        try await call(s.method, timeout: timeout)[s.key]
    }

    @discardableResult
    public func write(_ s: Setting, _ value: JSONValue) async throws -> JSONValue? {
        try await call(s.method, params: [s.key: value])[s.key]
    }

    /// Blocks until someone answers the Allow prompt on the monitor.
    public func pair() async throws -> String {
        token = nil
        let result = try await call("createAccessToken", timeout: 70, retry: false)
        guard let t = result["AccessToken"]?.stringValue else { throw IPControlError.badResponse }
        token = t
        return t
    }

    public func deviceInformation() async throws -> [String: JSONValue] {
        try await call("getDeviceInformation")
    }

    public func call(_ method: String, params: [String: JSONValue] = [:],
                     timeout: TimeInterval = 5, retry: Bool = true) async throws -> [String: JSONValue] {
        let previous = tail
        let work = Task { () throws -> [String: JSONValue] in
            await previous?.value
            do {
                return try await self.perform(method, params, timeout)
            } catch IPControlError.transport where retry {
                try await Task.sleep(for: .milliseconds(150))
                return try await self.perform(method, params, timeout)
            }
        }
        tail = Task { _ = await work.result }
        return try await work.value
    }

    private func perform(_ method: String, _ params: [String: JSONValue], _ timeout: TimeInterval) async throws
        -> [String: JSONValue] {
        var request = URLRequest(url: URL(string: "https://\(host):\(port)/")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try RPC.body(method: method, token: token, params: params)
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200, data.isEmpty {
                throw IPControlError.transport("HTTP \(http.statusCode)")
            }
            return try RPC.parse(data)
        } catch let e as IPControlError {
            throw e
        } catch {
            if delegate.mismatch { throw IPControlError.certificateChanged }
            throw IPControlError.transport(error.localizedDescription)
        }
    }
}

/// Keeps only the newest value per key, so dragging a slider never builds a backlog.
public actor LatestValueQueue<Key: Hashable & Sendable, Value: Sendable> {
    private var order: [Key] = []
    private var pending: [Key: Value] = [:]
    private var running = false
    private let send: @Sendable (Key, Value) async -> Void

    public init(send: @escaping @Sendable (Key, Value) async -> Void) { self.send = send }

    public var isIdle: Bool { !running }

    public func submit(_ key: Key, _ value: Value) {
        if pending[key] == nil { order.append(key) }
        pending[key] = value
        guard !running else { return }
        running = true
        Task { await pump() }
    }

    private func pump() async {
        while !order.isEmpty {
            let key = order.removeFirst()
            guard let value = pending.removeValue(forKey: key) else { continue }
            await send(key, value)
        }
        running = false
    }
}
