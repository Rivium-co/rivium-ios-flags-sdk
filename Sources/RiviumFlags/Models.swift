import Foundation

// MARK: - Configuration

/// Configuration for the Rivium Flags client.
public struct RiviumFlagsConfig: Sendable {
    /// Public project key (`rv_live_…` / `rv_test_…`). Never put a server secret in an app.
    public var apiKey: String
    /// Environment key (`development`, `staging`, `production`, custom). `nil` = the Default layer.
    public var environment: String?
    /// Only evaluate these flags. `nil` = every flag of the project.
    public var flagKeys: [String]?
    /// Polling while the app is in the foreground. `0` (default) = off; otherwise at least 60 s.
    /// Every evaluate request is a billed usage event, so keep this off unless you need it.
    public var refreshIntervalSeconds: TimeInterval
    /// Persist the last results on the device and serve them at start / offline.
    public var cacheEnabled: Bool
    /// Network timeout per request.
    public var requestTimeout: TimeInterval
    /// Verbose logs (never contain the API key).
    public var debug: Bool
    public var baseURL: URL

    public init(
        apiKey: String,
        environment: String? = nil,
        flagKeys: [String]? = nil,
        refreshIntervalSeconds: TimeInterval = 0,
        cacheEnabled: Bool = true,
        requestTimeout: TimeInterval = 10,
        debug: Bool = false,
        baseURL: URL = URL(string: "https://flags.rivium.co")!
    ) {
        self.apiKey = apiKey
        self.environment = environment
        self.flagKeys = flagKeys
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.cacheEnabled = cacheEnabled
        self.requestTimeout = requestTimeout
        self.debug = debug
        self.baseURL = baseURL
    }

    /// Effective polling interval: 0 (off) or ≥ 60 s.
    var effectivePollInterval: TimeInterval {
        refreshIntervalSeconds <= 0 ? 0 : max(60, refreshIntervalSeconds)
    }
}

// MARK: - Results

/// Why a flag has its value. Unknown server reasons are kept as-is.
public struct FlagReason: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let on = FlagReason(rawValue: "ON")
    public static let variant = FlagReason(rawValue: "VARIANT")
    public static let disabled = FlagReason(rawValue: "DISABLED")
    public static let prerequisiteFailed = FlagReason(rawValue: "PREREQUISITE_FAILED")
    public static let notTargeted = FlagReason(rawValue: "NOT_TARGETED")
    public static let outsideRollout = FlagReason(rawValue: "OUTSIDE_ROLLOUT")
    public static let noBucketingId = FlagReason(rawValue: "NO_BUCKETING_ID")
    public static let error = FlagReason(rawValue: "ERROR")
    /// SDK: key absent from the results; the code default is returned.
    public static let flagNotFound = FlagReason(rawValue: "FLAG_NOT_FOUND")
    /// SDK: no cached or fetched results yet; the code default is returned.
    public static let notReady = FlagReason(rawValue: "NOT_READY")
    /// SDK: a typed getter was called on a flag of another value type; the code default is returned.
    public static let typeMismatch = FlagReason(rawValue: "TYPE_MISMATCH")
}

/// The value type of a flag.
public enum FlagValueType: String, Codable, Sendable {
    case boolean, string, number, json
}

/// One evaluated flag as returned by `POST /public/v2/evaluate`.
public struct FlagResult: Equatable, Codable, Sendable {
    public let key: String
    /// Raw value type from the server (`boolean` / `string` / `number` / `json`).
    public let valueType: String
    public let enabled: Bool
    public let value: RiviumJSON
    public let variant: String?
    public let reason: FlagReason
    public let version: Int

    public var type: FlagValueType? { FlagValueType(rawValue: valueType) }

    public init(key: String, valueType: String, enabled: Bool, value: RiviumJSON, variant: String?, reason: FlagReason, version: Int) {
        self.key = key
        self.valueType = valueType
        self.enabled = enabled
        self.value = value
        self.variant = variant
        self.reason = reason
        self.version = version
    }

    /// Lenient parse of one entry of the `flags` map. Returns nil when the entry is unusable.
    init?(key: String, json: RiviumJSON) {
        guard let o = json.objectValue else { return nil }
        self.key = o["key"]?.stringValue ?? key
        self.valueType = o["valueType"]?.stringValue ?? "json"
        self.enabled = o["enabled"]?.boolValue ?? false
        self.value = o["value"] ?? .null
        self.variant = o["variant"]?.stringValue
        self.reason = FlagReason(rawValue: o["reason"]?.stringValue ?? "ERROR")
        self.version = o["version"]?.intValue ?? 0
    }
}

/// The full answer of a getter: the value your code should use plus why.
public struct FlagDetail<Value> {
    public let key: String
    public let value: Value
    public let enabled: Bool
    public let variant: String?
    public let reason: FlagReason
    /// Flag version on the server; nil for SDK reasons (NOT_READY, FLAG_NOT_FOUND).
    public let version: Int?
}

extension FlagDetail: Equatable where Value: Equatable {}
extension FlagDetail: Sendable where Value: Sendable {}

// MARK: - Events and errors

/// An error reported to listeners. The SDK never throws to the app from getters.
public struct RiviumFlagsError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        /// 400 / 413: the request body was refused; it is not retried.
        case invalidRequest
        /// 401: invalid key, Flags not enabled, or no Flags project. Automatic fetches stop until `refresh()`.
        case unauthorized
        /// 403: refused (for example an IP allow-list). Not retried automatically.
        case forbidden
        /// 404: the environment does not exist or is inactive. Not retried automatically.
        case environmentNotFound
        /// 429: rate limited; retried after `Retry-After` with back-off.
        case rateLimited
        /// 5xx: retried with back-off.
        case server
        /// Network failure / timeout; retried with back-off.
        case network
        /// The response could not be read.
        case invalidResponse
    }

    public let kind: Kind
    public let statusCode: Int?
    /// Server error code (e.g. `environment_not_found`) when present.
    public let code: String?
    public let message: String

    public var description: String {
        "Rivium Flags \(kind.rawValue)\(statusCode.map { " (\($0))" } ?? "")\(code.map { " \($0)" } ?? ""): \(message)"
    }
}

/// Events delivered to listeners on the main thread.
public enum RiviumFlagsEvent: Sendable {
    /// Results are available (from the device cache or the network). Fires once per client.
    case ready
    /// Results changed after a fetch. `changedKeys` lists added, removed or changed flags.
    case updated(changedKeys: Set<String>)
    case error(RiviumFlagsError)
}

/// Returned by `addListener`; pass it to `removeListener` (or keep it alive and call `cancel()`).
public final class RiviumFlagsListenerToken: @unchecked Sendable {
    let id = UUID()
    private let onCancel: (UUID) -> Void
    init(onCancel: @escaping (UUID) -> Void) { self.onCancel = onCancel }
    public func cancel() { onCancel(id) }
}
