import Foundation
import CryptoKit
import os

// MARK: - Version

enum SDKInfo {
    static let version = "0.2.0"
    static let header = "ios/\(version)"
}

// MARK: - Logging

struct FlagsLog {
    private static let logger = os.Logger(subsystem: "co.rivium.flags", category: "Rivium Flags")
    let debugEnabled: Bool

    func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        let m = message()
        FlagsLog.logger.debug("[Rivium Flags] \(m, privacy: .public)")
    }

    func warn(_ message: String) {
        FlagsLog.logger.warning("[Rivium Flags] \(message, privacy: .public)")
    }

    func error(_ message: String) {
        FlagsLog.logger.error("[Rivium Flags] \(message, privacy: .public)")
    }
}

// MARK: - Transport

/// Sends one request. Tests replace it; the default uses an ephemeral URLSession (no HTTP cache, so ETag/304
/// handling stays in the SDK).
protocol FlagsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: FlagsTransport {
    let session: URLSession

    init(timeout: TimeInterval) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.httpCookieStorage = nil
        session = URLSession(configuration: cfg)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

// MARK: - Context and cache

/// The context sent with every evaluate request.
struct EvalContext: Codable, Equatable, Sendable {
    var userId: String?
    var anonymousId: String
    var attributes: [String: RiviumJSON]
}

struct EvaluateBody: Encodable, Equatable {
    let environment: String?
    let context: EvalContext
    let flagKeys: [String]?
}

/// What is persisted on the device. Never contains the API key.
struct CachedEvaluation: Codable, Equatable {
    var keyFingerprint: String
    var environment: String?
    var flagKeys: [String]?
    var context: EvalContext
    var etag: String?
    var flags: [String: FlagResult]
    var fetchedAt: Date

    func matches(environment: String?, flagKeys: [String]?, context: EvalContext) -> Bool {
        self.environment == environment && self.flagKeys == flagKeys && self.context == context
    }
}

enum StorageKeys {
    /// Do not change: installed apps depend on this key.
    static let anonymousId = "co.rivium.flags.anonymousId"
    static let cache = "rivium_flags_cache_v2"
    static let context = "rivium_flags_context_v2"
    /// 0.1.x keys, removed on first use of 0.2.0.
    static let legacy = ["rivium_ff_cached_flags", "rivium_ff_user_id"]
}

func keyFingerprint(_ apiKey: String) -> String {
    let digest = SHA256.hash(data: Data(apiKey.utf8))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

func newAnonymousId() -> String { UUID().uuidString.lowercased() }

func isUsableId(_ s: String?) -> Bool {
    guard let s = s else { return false }
    return !s.isEmpty && s.count <= 256
}

// MARK: - Attributes

enum AttributeLimits {
    static let maxKeys = 100
    static let maxKeyLength = 100
    static let maxStringLength = 1024
    static let maxArrayLength = 100
}

/// Keeps only what the server accepts; drops the rest with a warning instead of getting a 400.
func sanitizeAttributes(_ input: [String: Any], log: FlagsLog) -> [String: RiviumJSON] {
    var out: [String: RiviumJSON] = [:]
    for key in input.keys.sorted() {
        if key == "userId" || key == "anonymousId" {
            log.warn("attribute \"\(key)\" is ignored; use identify() / the anonymous id instead")
            continue
        }
        guard !key.isEmpty, key.count <= AttributeLimits.maxKeyLength else {
            log.warn("attribute names are 1-\(AttributeLimits.maxKeyLength) characters; dropped one")
            continue
        }
        guard out.count < AttributeLimits.maxKeys else {
            log.warn("at most \(AttributeLimits.maxKeys) attributes; extra ones dropped")
            break
        }
        guard let json = RiviumJSON(any: input[key] ?? nil), let clean = cleanAttribute(json) else {
            log.warn("attribute \"\(key)\" must be a string, number, boolean, null or an array of those; dropped")
            continue
        }
        out[key] = clean
    }
    return out
}

private func isScalar(_ v: RiviumJSON) -> Bool {
    switch v {
    case .null, .bool, .number: return true
    case .string(let s): return s.count <= AttributeLimits.maxStringLength
    default: return false
    }
}

private func cleanAttribute(_ v: RiviumJSON) -> RiviumJSON? {
    if isScalar(v) { return v }
    if case .array(let items) = v, items.count <= AttributeLimits.maxArrayLength, items.allSatisfy(isScalar) { return v }
    return nil
}

// MARK: - Back-off

enum Backoff {
    static let defaultRetryAfter: TimeInterval = 5
    static let base: TimeInterval = 5
    static let max: TimeInterval = 300

    /// Delay before retry number `attempt` (0-based). `retryAfter` is the 429 header (or nil).
    /// `random` in 0...1 drives the ±20 % jitter. A server-given Retry-After is never shortened.
    static func delay(attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval {
        let start = retryAfter ?? base
        let exp = start * pow(2, Double(Swift.max(0, Swift.min(attempt, 20))))
        let capped = Swift.min(exp, max)
        let jittered = capped * (0.8 + 0.4 * Swift.min(Swift.max(random, 0), 1))
        if let ra = retryAfter, attempt == 0 { return Swift.max(ra, jittered) }
        return Swift.min(jittered, max)
    }

    /// Parses a Retry-After header (seconds or HTTP date). Missing / invalid → default 5 s.
    static func parseRetryAfter(_ header: String?, now: Date = Date()) -> TimeInterval {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return defaultRetryAfter }
        if let s = Double(h), s.isFinite, s >= 0 { return s }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: h) { return Swift.max(0, d.timeIntervalSince(now)) }
        return defaultRetryAfter
    }
}

// MARK: - Response parsing

enum ResponseParser {
    /// Parses a 200 body into the flags map. Nil when the body is not a v2 response.
    static func parseFlags(_ data: Data) -> (environment: String?, flags: [String: FlagResult])? {
        guard let json = try? JSONDecoder().decode(RiviumJSON.self, from: data),
              let root = json.objectValue,
              let flagsObj = root["flags"]?.objectValue else { return nil }
        var flags: [String: FlagResult] = [:]
        for (key, value) in flagsObj {
            if let r = FlagResult(key: key, json: value) { flags[key] = r }
        }
        return (root["environment"]?.stringValue, flags)
    }

    /// Extracts `code` and `message` from an error body, for logs.
    static func parseError(_ data: Data) -> (code: String?, message: String?) {
        guard let json = try? JSONDecoder().decode(RiviumJSON.self, from: data), let o = json.objectValue else {
            return (nil, nil)
        }
        let message: String?
        if let m = o["message"]?.stringValue {
            message = m
        } else if let arr = o["message"]?.arrayValue {
            message = arr.compactMap { $0.stringValue }.joined(separator: "; ")
        } else {
            message = nil
        }
        return (o["code"]?.stringValue, message)
    }
}
