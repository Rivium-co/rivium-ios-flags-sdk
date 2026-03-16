import Foundation
import CryptoKit

// MARK: - Configuration

public struct RiviumFlagsConfig {
    public let apiKey: String
    public let environment: String?
    public let baseUrl: String
    public let debug: Bool
    public let enableOfflineCache: Bool

    public init(
        apiKey: String,
        environment: String? = nil,
        baseUrl: String = "https://flags.rivium.co",
        debug: Bool = false,
        enableOfflineCache: Bool = true
    ) {
        self.apiKey = apiKey
        self.environment = environment
        self.baseUrl = baseUrl
        self.debug = debug
        self.enableOfflineCache = enableOfflineCache
    }
}

// MARK: - Models

public struct FeatureFlag {
    public let key: String
    public let enabled: Bool
    public let rolloutPercentage: Int
    public let targetingRules: [String: Any]?
    public let variants: [FlagVariant]?
    public let defaultValue: Any?
}

public struct FlagVariant {
    public let key: String
    public let value: Any?
    public let weight: Int
}

public struct FlagEvalResult {
    public let enabled: Bool
    public let value: Any?
    public let variant: String?
}

public typealias FeatureFlagCallback = (_ event: String, _ data: [String: Any]?) -> Void

// MARK: - RiviumFlags SDK

/// RiviumFlags - Client-side Feature Flags SDK for iOS
///
/// ```swift
/// let flags = RiviumFlags(config: RiviumFlagsConfig(apiKey: "rv_live_xxx"))
/// try await flags.initialize()
///
/// flags.setUserId("user-123")
///
/// if flags.isEnabled("dark-mode") {
///     // dark mode enabled
/// }
/// ```
public class RiviumFlags {

    public static var shared: RiviumFlags?

    private let config: RiviumFlagsConfig
    private var flags: [FeatureFlag] = []
    private var userId: String?
    private var userAttributes: [String: Any] = [:]
    private var isInitialized = false
    private var callback: FeatureFlagCallback?

    private let cacheKey = "rivium_ff_cached_flags"
    private let userIdKey = "rivium_ff_user_id"

    public init(config: RiviumFlagsConfig) {
        self.config = config
    }

    /// Initialize the SDK
    public func initialize(callback: FeatureFlagCallback? = nil) async throws {
        self.callback = callback

        // Load cached data
        if config.enableOfflineCache {
            loadCachedFlags()
            userId = UserDefaults.standard.string(forKey: userIdKey)
        }

        isInitialized = true
        RiviumFlags.shared = self

        await fetchFlags()

        callback?("initialized", ["count": flags.count])
    }

    public func setUserId(_ userId: String) {
        self.userId = userId
        if config.enableOfflineCache {
            UserDefaults.standard.set(userId, forKey: userIdKey)
        }
    }

    public func getUserId() -> String? { userId }

    public func setUserAttributes(_ attributes: [String: Any]) {
        userAttributes.merge(attributes) { _, new in new }
    }

    /// Check if a feature flag is enabled
    public func isEnabled(_ flagKey: String, defaultValue: Bool = false) -> Bool {
        guard let flag = flags.first(where: { $0.key == flagKey }) else { return defaultValue }
        return evaluateFlag(flag).enabled
    }

    /// Get the value of a feature flag
    public func getValue(_ flagKey: String, defaultValue: Any? = nil) -> Any? {
        guard let flag = flags.first(where: { $0.key == flagKey }) else { return defaultValue }
        let result = evaluateFlag(flag)
        return result.value ?? defaultValue
    }

    /// Evaluate a flag and get the full result
    public func evaluate(_ flagKey: String) -> FlagEvalResult {
        guard let flag = flags.first(where: { $0.key == flagKey }) else {
            return FlagEvalResult(enabled: false, value: false, variant: nil)
        }
        return evaluateFlag(flag)
    }

    /// Get all flags
    public func getAll() -> [FeatureFlag] { flags }

    /// Refresh flags from the server
    public func refresh() async {
        await fetchFlags()
        callback?("featureFlagsRefreshed", ["count": flags.count])
    }

    /// Reset all state
    public func reset() {
        flags = []
        userId = nil
        userAttributes = [:]
        isInitialized = false
        RiviumFlags.shared = nil
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: userIdKey)
    }

    /// Dispose the SDK instance
    public func dispose() {
        flags = []
        userId = nil
        userAttributes = [:]
        isInitialized = false
        RiviumFlags.shared = nil
    }

    // MARK: - Private

    private var flagsUrl: URL {
        var urlString = "\(config.baseUrl)/public/flags"
        if let env = config.environment {
            urlString += "?environment=\(env.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? env)"
        }
        guard let url = URL(string: urlString) else {
            fatalError("[RiviumFlags] Invalid URL: \(urlString)")
        }
        return url
    }

    private func fetchFlags() async {
        var request = URLRequest(url: flagsUrl)
        request.addValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NSError(domain: "RiviumFlags", code: -1, userInfo: [NSLocalizedDescriptionKey: "HTTP error"])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let flagsArray = json["flags"] as? [[String: Any]] else { return }

            flags = flagsArray.map { parseFlag($0) }

            if config.enableOfflineCache {
                UserDefaults.standard.set(data, forKey: cacheKey)
            }

            if config.debug {
                print("[RiviumFlags] Fetched \(flags.count) flags")
            }
        } catch {
            if config.debug {
                print("[RiviumFlags] Failed to fetch flags: \(error)")
            }
            callback?("error", ["message": "Failed to fetch flags: \(error.localizedDescription)"])
        }
    }

    private func loadCachedFlags() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flagsArray = json["flags"] as? [[String: Any]] else { return }
        flags = flagsArray.map { parseFlag($0) }
    }

    private func parseFlag(_ dict: [String: Any]) -> FeatureFlag {
        let clean = (stripNulls(dict) as? [String: Any]) ?? dict

        let variants = (clean["variants"] as? [[String: Any]])?.map { v in
            FlagVariant(
                key: v["key"] as? String ?? "",
                value: v["value"],
                weight: v["weight"] as? Int ?? 0
            )
        }

        return FeatureFlag(
            key: clean["key"] as? String ?? "",
            enabled: clean["enabled"] as? Bool ?? false,
            rolloutPercentage: clean["rolloutPercentage"] as? Int ?? 100,
            targetingRules: clean["targetingRules"] as? [String: Any],
            variants: variants,
            defaultValue: clean["defaultValue"]
        )
    }

    /// Recursively strip NSNull from JSONSerialization output.
    /// NSNull is NOT Swift nil — it passes `as? Any`, breaks ?? operator,
    /// and crashes in string interpolation.
    private func stripNulls(_ value: Any) -> Any? {
        if value is NSNull { return nil }
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (k, v) in dict {
                if let cleaned = stripNulls(v) {
                    result[k] = cleaned
                }
            }
            return result
        }
        if let arr = value as? [Any] {
            return arr.compactMap { stripNulls($0) }
        }
        return value
    }

    private func evaluateFlag(_ flag: FeatureFlag) -> FlagEvalResult {
        guard flag.enabled else {
            return FlagEvalResult(enabled: false, value: flag.defaultValue ?? false, variant: nil)
        }

        if let rules = flag.targetingRules, !rules.isEmpty {
            if !evaluateTargetingRules(rules, userContext: userAttributes) {
                return FlagEvalResult(enabled: false, value: flag.defaultValue ?? false, variant: nil)
            }
        }

        if let uid = userId {
            let bucket = getBucket(userId: uid, salt: flag.key)
            if bucket >= flag.rolloutPercentage {
                return FlagEvalResult(enabled: false, value: flag.defaultValue ?? false, variant: nil)
            }
        }

        if let variants = flag.variants, !variants.isEmpty {
            let variantBucket = getVariantBucket(userId: userId ?? "", flagKey: flag.key)
            var cumulative = 0
            for variant in variants {
                cumulative += variant.weight
                if variantBucket < cumulative {
                    return FlagEvalResult(enabled: true, value: variant.value, variant: variant.key)
                }
            }
            return FlagEvalResult(enabled: true, value: variants.first?.value, variant: variants.first?.key)
        }

        return FlagEvalResult(enabled: true, value: true, variant: nil)
    }

    private func evaluateTargetingRules(_ rules: [String: Any], userContext: [String: Any]) -> Bool {
        // Handle nested { operator, rules } format from dashboard
        if let ruleList = rules["rules"] as? [[String: Any]] {
            let op = (rules["operator"] as? String ?? "AND").uppercased()
            if op == "OR" {
                return ruleList.contains { evaluateNestedRule($0, userContext: userContext) }
            }
            return ruleList.allSatisfy { evaluateNestedRule($0, userContext: userContext) }
        }
        // Legacy flat format
        for (key, rule) in rules {
            if !evaluateRule(key: key, rule: rule, context: userContext) { return false }
        }
        return true
    }

    private func evaluateNestedRule(_ rule: [String: Any], userContext: [String: Any]) -> Bool {
        guard let attribute = rule["attribute"] as? String,
              let op = rule["operator"] as? String else { return true }
        let ruleValue = rule["value"]
        let userValue = userContext[attribute]

        switch op {
        case "equals":
            return isEqual(userValue, ruleValue)
        case "not_equals", "notEquals":
            return !isEqual(userValue, ruleValue)
        case "in":
            let list: [String]
            if let str = ruleValue as? String {
                list = str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let arr = ruleValue as? [String] {
                list = arr
            } else { return false }
            return list.contains { isEqual(userValue, $0) }
        case "not_in", "notIn":
            let list: [String]
            if let str = ruleValue as? String {
                list = str.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if let arr = ruleValue as? [String] {
                list = arr
            } else { return true }
            return !list.contains { isEqual(userValue, $0) }
        case "greater_than", "greaterThan":
            if let v = userValue as? Double, let r = ruleValue as? Double { return v > r }
            return false
        case "less_than", "lessThan":
            if let v = userValue as? Double, let r = ruleValue as? Double { return v < r }
            return false
        case "contains":
            if let v = userValue as? String, let r = ruleValue as? String { return v.contains(r) }
            return false
        case "regex":
            if let v = userValue as? String, let r = ruleValue as? String {
                return (try? NSRegularExpression(pattern: r).firstMatch(in: v, range: NSRange(v.startIndex..., in: v))) != nil
            }
            return false
        case "exists":
            let exists = ruleValue as? Bool ?? true
            return exists ? userValue != nil : userValue == nil
        default:
            return isEqual(userValue, ruleValue)
        }
    }

    private func evaluateRule(key: String, rule: Any, context: [String: Any]) -> Bool {
        let value = context[key]

        if let ruleDict = rule as? [String: Any] {
            if let eq = ruleDict["equals"] { return isEqual(value, eq) }
            if let neq = ruleDict["notEquals"] { return !isEqual(value, neq) }
            if let list = ruleDict["in"] as? [Any] { return list.contains { isEqual(value, $0) } }
            if let list = ruleDict["notIn"] as? [Any] { return !list.contains { isEqual(value, $0) } }
            if let gt = ruleDict["greaterThan"] as? Double, let v = value as? Double { return v > gt }
            if let lt = ruleDict["lessThan"] as? Double, let v = value as? Double { return v < lt }
            if let gte = ruleDict["greaterThanOrEqual"] as? Double, let v = value as? Double { return v >= gte }
            if let lte = ruleDict["lessThanOrEqual"] as? Double, let v = value as? Double { return v <= lte }
            if let sub = ruleDict["contains"] as? String, let v = value as? String { return v.contains(sub) }
            if let pattern = ruleDict["regex"] as? String, let v = value as? String {
                return (try? NSRegularExpression(pattern: pattern).firstMatch(in: v, range: NSRange(v.startIndex..., in: v))) != nil
            }
            if let exists = ruleDict["exists"] as? Bool { return exists ? value != nil : value == nil }
            if let andRules = ruleDict["and"] as? [Any] {
                return andRules.allSatisfy { evaluateRule(key: key, rule: $0, context: context) }
            }
            if let orRules = ruleDict["or"] as? [Any] {
                return orRules.contains { evaluateRule(key: key, rule: $0, context: context) }
            }
        }

        return isEqual(value, rule)
    }

    private func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        if let a = a as? String, let b = b as? String { return a == b }
        if let a = a as? Bool, let b = b as? Bool { return a == b }
        if let a = a as? Double, let b = b as? Double { return a == b }
        if let a = a as? Int, let b = b as? Int { return a == b }
        return false
    }

    private func getBucket(userId: String, salt: String) -> Int {
        let input = "\(userId):\(salt)"
        let data = Data(input.utf8)
        let hash = Insecure.MD5.hash(data: data)
        let hex = hash.prefix(4).map { String(format: "%02x", $0) }.joined()
        let value = UInt64(hex, radix: 16) ?? 0
        return Int(value % 100)
    }

    private func getVariantBucket(userId: String, flagKey: String) -> Int {
        return getBucket(userId: userId, salt: "\(flagKey):variant")
    }
}
