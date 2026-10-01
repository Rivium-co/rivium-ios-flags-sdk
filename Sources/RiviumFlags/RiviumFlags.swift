import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Rivium Flags client for iOS and macOS.
///
/// Flags are evaluated on the Rivium Flags server (`POST /public/v2/evaluate`) for the current context; the SDK keeps
/// only the results, caches them on the device and serves them offline. No targeting rules ever reach the app.
///
/// ```swift
/// let flags = RiviumFlags(config: RiviumFlagsConfig(apiKey: "rv_live_xxx", environment: "production"))
/// flags.start()
/// flags.identify("user-123", attributes: ["plan": "pro"])
///
/// if flags.isEnabled("new-checkout") { … }
/// let theme = flags.getString("theme", default: "light")
/// ```
///
/// Thread-safe. Getters never block on the network and never throw. Listener callbacks run on the main thread.
public final class RiviumFlags: @unchecked Sendable {

    public let config: RiviumFlagsConfig

    private let transport: FlagsTransport
    private let defaults: UserDefaults
    private let callbackQueue: DispatchQueue
    private let log: FlagsLog
    private let fingerprint: String
    private let debounceInterval: TimeInterval
    private let random: @Sendable () -> Double
    private let lock = NSLock()
    private let refusedKey: Bool

    // MARK: State (guarded by `lock`)
    private var anonId: String
    private var userId: String?
    private var attributes: [String: RiviumJSON] = [:]
    private var cache: CachedEvaluation?
    private var readyFired = false
    private var started = false
    private var closed = false
    private var generation = 0
    private var inFlight: Task<Bool, Never>?
    private var debounceTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var failures = 0
    private var blockedStatus: Int?
    private var rejectedBody: Data?
    private var lastSuccessAt: Date?
    private var pendingRetry = false
    private var isForeground = true
    private var listeners: [UUID: (RiviumFlagsEvent) -> Void] = [:]
    private var readyWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var observers: [NSObjectProtocol] = []

    static let foregroundStaleAfter: TimeInterval = 15 * 60

    // MARK: - Init

    /// Creates a client. Loads the anonymous id and the cached results from the device; does not touch the
    /// network until `start()`.
    public convenience init(config: RiviumFlagsConfig) {
        self.init(
            config: config,
            transport: URLSessionTransport(timeout: config.requestTimeout),
            defaults: .standard,
            callbackQueue: .main
        )
    }

    init(
        config: RiviumFlagsConfig,
        transport: FlagsTransport,
        defaults: UserDefaults,
        callbackQueue: DispatchQueue,
        debounceInterval: TimeInterval = 0.25,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.config = config
        self.transport = transport
        self.defaults = defaults
        self.callbackQueue = callbackQueue
        self.debounceInterval = debounceInterval
        self.random = random
        self.log = FlagsLog(debugEnabled: config.debug)
        self.fingerprint = keyFingerprint(config.apiKey)
        // A server secret must never be used (or sent) from an app: refuse it, the client stays offline.
        self.refusedKey = config.apiKey.hasPrefix("rv_srv_")

        if let stored = defaults.string(forKey: StorageKeys.anonymousId), isUsableId(stored) {
            anonId = stored
        } else {
            anonId = newAnonymousId()
            defaults.set(anonId, forKey: StorageKeys.anonymousId)
        }

        for key in StorageKeys.legacy { defaults.removeObject(forKey: key) }

        if config.apiKey.isEmpty { log.error("apiKey is empty") }
        if refusedKey {
            log.error("a server secret (rv_srv_…) was passed as apiKey; refused — use the public project key in apps")
        }

        if config.cacheEnabled { loadPersisted() } else {
            defaults.removeObject(forKey: StorageKeys.cache)
        }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        inFlight?.cancel(); debounceTask?.cancel(); retryTask?.cancel(); pollTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Serves the cached results (if any) and fetches fresh ones. Safe to call more than once.
    public func start() {
        let (proceed, hasResults): (Bool, Bool) = locked {
            guard !started, !closed else { return (false, false) }
            started = true
            return (true, cache != nil)
        }
        guard proceed else { return }
        installLifecycleObservers()
        if hasResults { resultsAvailable() }
        Task.detached { [self] in _ = await self.fetch(explicit: false) }
        startPolling()
    }

    /// Waits until results are available (cache or network) or `timeout` passes. Returns `isReady`.
    public func waitUntilReady(timeout: TimeInterval = 5) async -> Bool {
        if isReady { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let id = UUID()
            let immediate: Bool? = locked {
                if cache != nil { return true }
                if closed { return false }
                readyWaiters[id] = cont
                return nil
            }
            if let immediate = immediate { cont.resume(returning: immediate); return }
            Task.detached { [self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                let waiter = self.locked { self.readyWaiters.removeValue(forKey: id) }
                waiter?.resume(returning: false)
            }
        }
    }

    /// Fetches fresh results now. Also clears a stop caused by 401/403/404 so automatic fetches resume.
    /// Returns true when the results are current (200 or 304).
    @discardableResult
    public func refresh() async -> Bool {
        let ok = await fetch(explicit: true)
        startPolling()
        return ok
    }

    /// Callback form of `refresh()`; `completion` runs on the main thread.
    public func refresh(completion: @escaping (Bool) -> Void) {
        Task.detached { [self] in
            let ok = await self.refresh()
            self.callbackQueue.async { completion(ok) }
        }
    }

    /// Stops all network work and listeners. The cached results stay on the device.
    public func close() {
        let (waiters, obs): ([CheckedContinuation<Bool, Never>], [NSObjectProtocol]) = locked {
            closed = true
            generation += 1
            inFlight?.cancel(); inFlight = nil
            debounceTask?.cancel(); debounceTask = nil
            retryTask?.cancel(); retryTask = nil
            pollTask?.cancel(); pollTask = nil
            listeners.removeAll()
            let w = Array(readyWaiters.values)
            readyWaiters.removeAll()
            let o = observers
            observers.removeAll()
            return (w, o)
        }
        for o in obs { NotificationCenter.default.removeObserver(o) }
        for w in waiters { w.resume(returning: false) }
    }

    // MARK: - Context

    /// The install's anonymous id (UUID v4). Sent with every request; survives `reset()`.
    public var anonymousId: String { locked { anonId } }

    /// The current user id, or nil when signed out.
    public var currentUserId: String? { locked { userId } }

    /// The current targeting attributes.
    public var currentAttributes: [String: RiviumJSON] { locked { attributes } }

    /// Sets the signed-in user and (optionally) replaces the attributes. `attributes: nil` keeps the current ones.
    /// A different user id drops the cached results of the previous user immediately. Refetches (debounced 250 ms).
    public func identify(_ userId: String?, attributes: [String: Any]? = nil) {
        let clean = attributes.map { sanitizeAttributes($0, log: log) }
        updateContext(userId: .some(userId), attributes: clean)
    }

    /// Sets (or clears, with nil) the user id. Keeps the attributes.
    public func setUserId(_ userId: String?) {
        updateContext(userId: .some(userId), attributes: nil)
    }

    /// Replaces all targeting attributes. Values: String, number, Bool, nil/NSNull or arrays of those.
    public func setAttributes(_ attributes: [String: Any]) {
        updateContext(userId: .none, attributes: sanitizeAttributes(attributes, log: log))
    }

    /// Sign-out: clears the user id, attributes and cached results. Keeps the anonymous id. Refetches.
    public func reset() {
        locked {
            userId = nil
            attributes = [:]
            cache = nil
            generation += 1
            inFlight?.cancel(); inFlight = nil
            retryTask?.cancel(); retryTask = nil
            defaults.removeObject(forKey: StorageKeys.cache)
        }
        scheduleContextFetch()
    }

    /// Generates and stores a new anonymous id (the install is re-bucketed). Returns the new id.
    @discardableResult
    public func resetAnonymousId() -> String {
        let id: String = locked {
            anonId = newAnonymousId()
            defaults.set(anonId, forKey: StorageKeys.anonymousId)
            generation += 1
            inFlight?.cancel(); inFlight = nil
            return anonId
        }
        scheduleContextFetch()
        return id
    }

    // MARK: - Getters

    /// True when results are available (from the device cache or the network).
    public var isReady: Bool { locked { cache != nil } }

    /// The flag's `enabled` (true only for reasons ON / VARIANT); `default` when not ready or not found.
    public func isEnabled(_ key: String, default defaultValue: Bool = false) -> Bool {
        let (ready, result) = snapshot(key)
        guard ready, let r = result else { return defaultValue }
        return r.enabled
    }

    public func getBoolean(_ key: String, default defaultValue: Bool) -> Bool {
        booleanDetail(key, default: defaultValue).value
    }

    public func getString(_ key: String, default defaultValue: String) -> String {
        stringDetail(key, default: defaultValue).value
    }

    public func getNumber(_ key: String, default defaultValue: Double) -> Double {
        numberDetail(key, default: defaultValue).value
    }

    public func getJson(_ key: String, default defaultValue: RiviumJSON) -> RiviumJSON {
        jsonDetail(key, default: defaultValue).value
    }

    /// Decodes a `json` flag into `T`; `default` when not ready, not found, another type or not decodable.
    public func getJson<T: Decodable>(_ key: String, as type: T.Type, default defaultValue: T) -> T {
        let d = jsonDetail(key, default: .null)
        guard d.reason != .notReady, d.reason != .flagNotFound, d.reason != .typeMismatch,
              let v = try? d.value.decode(T.self) else { return defaultValue }
        return v
    }

    public func booleanDetail(_ key: String, default defaultValue: Bool) -> FlagDetail<Bool> {
        detail(key, default: defaultValue, expected: .boolean) { $0.boolValue }
    }

    public func stringDetail(_ key: String, default defaultValue: String) -> FlagDetail<String> {
        detail(key, default: defaultValue, expected: .string) { $0.stringValue }
    }

    public func numberDetail(_ key: String, default defaultValue: Double) -> FlagDetail<Double> {
        detail(key, default: defaultValue, expected: .number) { $0.numberValue }
    }

    public func jsonDetail(_ key: String, default defaultValue: RiviumJSON) -> FlagDetail<RiviumJSON> {
        detail(key, default: defaultValue, expected: .json) { $0 }
    }

    /// Untyped detail: the served value whatever the flag's type (no TYPE_MISMATCH).
    public func getDetail(_ key: String, default defaultValue: RiviumJSON = nil) -> FlagDetail<RiviumJSON> {
        detail(key, default: defaultValue, expected: nil) { $0 }
    }

    /// Every result currently held (empty when not ready).
    public func getAll() -> [String: FlagResult] { locked { cache?.flags ?? [:] } }

    // MARK: - Listeners

    /// Adds a listener; events arrive on the main thread. Keep the token to remove it.
    @discardableResult
    public func addListener(_ handler: @escaping (RiviumFlagsEvent) -> Void) -> RiviumFlagsListenerToken {
        let token = RiviumFlagsListenerToken { [weak self] id in self?.removeListener(id) }
        locked { listeners[token.id] = handler }
        return token
    }

    public func removeListener(_ token: RiviumFlagsListenerToken) { removeListener(token.id) }

    private func removeListener(_ id: UUID) { locked { _ = listeners.removeValue(forKey: id) } }

    // MARK: - Internals: getters

    private func snapshot(_ key: String) -> (Bool, FlagResult?) {
        locked { (cache != nil, cache?.flags[key]) }
    }

    private func detail<T>(
        _ key: String,
        default defaultValue: T,
        expected: FlagValueType?,
        extract: (RiviumJSON) -> T?
    ) -> FlagDetail<T> {
        let (ready, result) = snapshot(key)
        guard ready else {
            return FlagDetail(key: key, value: defaultValue, enabled: false, variant: nil, reason: .notReady, version: nil)
        }
        guard let r = result else {
            return FlagDetail(key: key, value: defaultValue, enabled: false, variant: nil, reason: .flagNotFound, version: nil)
        }
        if let expected = expected, r.valueType != expected.rawValue {
            return FlagDetail(key: key, value: defaultValue, enabled: false, variant: nil, reason: .typeMismatch, version: r.version)
        }
        // Right type but no usable value (e.g. an off value of null served as false): code default, server reason.
        let value = extract(r.value) ?? defaultValue
        return FlagDetail(key: key, value: value, enabled: r.enabled, variant: r.variant, reason: r.reason, version: r.version)
    }

    // MARK: - Internals: context

    private func updateContext(userId newUserId: String??, attributes newAttributes: [String: RiviumJSON]?) {
        if case .some(.some(let id)) = newUserId, !id.isEmpty, id.count > 256 {
            log.error("userId must be 1-256 characters; identify ignored")
            return
        }
        let changed: Bool = locked {
            var changed = false
            if case .some(let raw) = newUserId {
                let id = (raw?.isEmpty ?? true) ? nil : raw
                if id != userId {
                    userId = id
                    changed = true
                    // Another user: never serve the previous user's results.
                    cache = nil
                    defaults.removeObject(forKey: StorageKeys.cache)
                }
            }
            if let attrs = newAttributes, attrs != attributes {
                attributes = attrs
                changed = true
            }
            if changed {
                generation += 1
                inFlight?.cancel(); inFlight = nil
                retryTask?.cancel(); retryTask = nil
                persistContextLocked()
            }
            return changed
        }
        if changed { scheduleContextFetch() }
    }

    private func scheduleContextFetch() {
        locked {
            if !config.cacheEnabled { defaults.removeObject(forKey: StorageKeys.context) } else { persistContextLocked() }
            debounceTask?.cancel()
            guard started, !closed else { debounceTask = nil; return }
            let delay = debounceInterval
            debounceTask = Task.detached { [self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                _ = await self.fetch(explicit: false)
            }
        }
    }

    private func currentContextLocked() -> EvalContext {
        EvalContext(userId: userId, anonymousId: anonId, attributes: attributes)
    }

    // MARK: - Internals: network

    func buildRequest(body: Data, etag: String?) -> URLRequest {
        var req = URLRequest(url: config.baseURL.appendingPathComponent("public/v2/evaluate"))
        req.httpMethod = "POST"
        req.timeoutInterval = config.requestTimeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(SDKInfo.header, forHTTPHeaderField: "x-rivium-sdk")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let etag = etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        req.httpBody = body
        return req
    }

    static func encodeBody(_ body: EvaluateBody) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(body)) ?? Data("{}".utf8)
    }

    /// One request in flight; a newer call supersedes the older one (last write wins).
    func fetch(explicit: Bool) async -> Bool {
        let task: Task<Bool, Never>? = locked {
            if closed || refusedKey { return nil }
            if explicit {
                blockedStatus = nil
            } else if blockedStatus != nil {
                return nil
            }
            let ctx = currentContextLocked()
            let body = Self.encodeBody(EvaluateBody(environment: config.environment, context: ctx, flagKeys: config.flagKeys))
            if !explicit, let rejected = rejectedBody, rejected == body { return nil }
            let etag: String? = (cache?.matches(environment: config.environment, flagKeys: config.flagKeys, context: ctx) == true)
                ? cache?.etag : nil
            generation += 1
            let gen = generation
            inFlight?.cancel()
            retryTask?.cancel(); retryTask = nil
            pendingRetry = false
            let t = Task.detached { [self] in await self.perform(gen: gen, body: body, context: ctx, etag: etag) }
            inFlight = t
            return t
        }
        guard let task = task else { return false }
        return await task.value
    }

    private func perform(gen: Int, body: Data, context: EvalContext, etag: String?) async -> Bool {
        let request = buildRequest(body: body, etag: etag)
        log.debug("evaluate \(context.userId == nil ? "anonymous" : "user") context\(etag == nil ? "" : " (If-None-Match)")")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
            failed(gen: gen, error: RiviumFlagsError(kind: .network, statusCode: nil, code: nil,
                                                     message: error.localizedDescription), retryAfter: nil)
            return false
        }
        if Task.isCancelled { return false }
        return handle(gen: gen, status: response.statusCode, data: data, response: response, body: body, context: context, sentEtag: etag)
    }

    private func handle(gen: Int, status: Int, data: Data, response: HTTPURLResponse, body: Data,
                        context: EvalContext, sentEtag: String?) -> Bool {
        switch status {
        case 200:
            guard let parsed = ResponseParser.parseFlags(data) else {
                failed(gen: gen, error: RiviumFlagsError(kind: .invalidResponse, statusCode: 200, code: nil,
                                                         message: "response is not a Rivium Flags v2 result"), retryAfter: nil)
                return false
            }
            let etag = response.value(forHTTPHeaderField: "ETag")
            let changed: Set<String>? = locked {
                guard gen == generation, !closed else { return nil }
                let old = cache?.flags ?? [:]
                let next = CachedEvaluation(keyFingerprint: fingerprint, environment: config.environment,
                                            flagKeys: config.flagKeys, context: context, etag: etag,
                                            flags: parsed.flags, fetchedAt: Date())
                cache = next
                lastSuccessAt = next.fetchedAt
                failures = 0
                rejectedBody = nil
                persistCacheLocked()
                var diff = Set<String>()
                for k in Set(old.keys).union(parsed.flags.keys) where old[k] != parsed.flags[k] { diff.insert(k) }
                return diff
            }
            guard let changedKeys = changed else { return false }
            log.debug("received \(parsed.flags.count) flag results")
            resultsAvailable()
            if !changedKeys.isEmpty { emit(.updated(changedKeys: changedKeys)) }
            return true

        case 304:
            let ok: Bool? = locked {
                guard gen == generation, !closed else { return nil }
                guard cache != nil, sentEtag != nil else { return false }
                cache?.fetchedAt = Date()
                lastSuccessAt = cache?.fetchedAt
                failures = 0
                persistCacheLocked()
                return true
            }
            guard let current = ok else { return false }
            if !current {
                failed(gen: gen, error: RiviumFlagsError(kind: .invalidResponse, statusCode: 304, code: nil,
                                                         message: "304 without cached results"), retryAfter: nil)
                return false
            }
            log.debug("results unchanged (304)")
            resultsAvailable()
            return true

        default:
            let (code, message) = ResponseParser.parseError(data)
            let msg = message ?? HTTPURLResponse.localizedString(forStatusCode: status)
            switch status {
            case 400, 413:
                let stale = locked { () -> Bool in
                    guard gen == generation else { return true }
                    rejectedBody = body
                    return false
                }
                if stale { return false }
                report(RiviumFlagsError(kind: .invalidRequest, statusCode: status, code: code, message: msg))
            case 401, 403, 404:
                let kind: RiviumFlagsError.Kind = status == 401 ? .unauthorized : (status == 403 ? .forbidden : .environmentNotFound)
                let stale = locked { () -> Bool in
                    guard gen == generation else { return true }
                    blockedStatus = status
                    pollTask?.cancel(); pollTask = nil
                    retryTask?.cancel(); retryTask = nil
                    return false
                }
                if stale { return false }
                report(RiviumFlagsError(kind: kind, statusCode: status, code: code, message: msg))
            case 429:
                let retryAfter = Backoff.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                failed(gen: gen, error: RiviumFlagsError(kind: .rateLimited, statusCode: status, code: code, message: msg),
                       retryAfter: retryAfter)
            default:
                failed(gen: gen, error: RiviumFlagsError(kind: status >= 500 ? .server : .invalidResponse,
                                                         statusCode: status, code: code, message: msg), retryAfter: nil)
            }
            return false
        }
    }

    /// Network / 5xx / 429: keep serving the cache and retry with back-off.
    private func failed(gen: Int, error: RiviumFlagsError, retryAfter: TimeInterval?) {
        let delay: TimeInterval? = locked {
            guard gen == generation, !closed else { return nil }
            let d = Backoff.delay(attempt: failures, retryAfter: retryAfter, random: random())
            failures += 1
            retryTask?.cancel()
            retryTask = Task.detached { [self] in
                try? await Task.sleep(nanoseconds: UInt64(d * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.retryFired()
            }
            return d
        }
        guard let d = delay else { return }
        report(error, suffix: String(format: "; retrying in %.0f s", d))
    }

    private func retryFired() {
        let go: Bool = locked {
            retryTask = nil
            guard !closed else { return false }
            if !isForeground { pendingRetry = true; return false }
            return true
        }
        if go { Task.detached { [self] in _ = await self.fetch(explicit: false) } }
    }

    private func report(_ error: RiviumFlagsError, suffix: String = "") {
        switch error.kind {
        case .network, .server, .rateLimited: log.warn(error.description + suffix)
        default: log.error(error.description + suffix)
        }
        emit(.error(error))
    }

    // MARK: - Internals: events

    private func resultsAvailable() {
        let (fireReady, waiters): (Bool, [CheckedContinuation<Bool, Never>]) = locked {
            let w = Array(readyWaiters.values)
            readyWaiters.removeAll()
            let fire = !readyFired && !closed
            readyFired = true
            return (fire, w)
        }
        for w in waiters { w.resume(returning: true) }
        if fireReady { emit(.ready) }
    }

    private func emit(_ event: RiviumFlagsEvent) {
        let handlers = locked { Array(listeners.values) }
        guard !handlers.isEmpty else { return }
        callbackQueue.async { for h in handlers { h(event) } }
    }

    // MARK: - Internals: polling and app lifecycle

    private func startPolling() {
        let interval = config.effectivePollInterval
        guard interval > 0 else { return }
        locked {
            guard started, !closed, isForeground, blockedStatus == nil, pollTask == nil else { return }
            pollTask = Task.detached { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    _ = await self.fetch(explicit: false)
                }
            }
        }
    }

    private func stopPolling() {
        locked { pollTask?.cancel(); pollTask = nil }
    }

    func didEnterForeground() {
        let shouldFetch: Bool = locked {
            isForeground = true
            guard started, !closed else { return false }
            let stale = lastSuccessAt.map { Date().timeIntervalSince($0) > Self.foregroundStaleAfter } ?? true
            let go = stale || pendingRetry
            pendingRetry = false
            return go
        }
        if shouldFetch { Task.detached { [self] in _ = await self.fetch(explicit: false) } }
        startPolling()
    }

    func didEnterBackground() {
        locked { isForeground = false }
        stopPolling()
    }

    private func installLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        let nc = NotificationCenter.default
        let fg = nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.didEnterForeground()
        }
        let bg = nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.didEnterBackground()
        }
        locked { observers.append(contentsOf: [fg, bg]) }
        #endif
    }

    // MARK: - Internals: persistence

    private func loadPersisted() {
        if let data = defaults.data(forKey: StorageKeys.context),
           let ctx = try? JSONDecoder().decode(PersistedContext.self, from: data) {
            userId = ctx.userId
            attributes = ctx.attributes
        }
        guard let data = defaults.data(forKey: StorageKeys.cache) else { return }
        guard let cached = try? JSONDecoder().decode(CachedEvaluation.self, from: data),
              cached.keyFingerprint == fingerprint,
              cached.environment == config.environment,
              cached.context.userId == userId else {
            defaults.removeObject(forKey: StorageKeys.cache)
            return
        }
        cache = cached
        lastSuccessAt = cached.fetchedAt
    }

    private func persistCacheLocked() {
        guard config.cacheEnabled, let c = cache, let data = try? JSONEncoder().encode(c) else { return }
        defaults.set(data, forKey: StorageKeys.cache)
    }

    private func persistContextLocked() {
        guard config.cacheEnabled else { return }
        if userId == nil && attributes.isEmpty {
            defaults.removeObject(forKey: StorageKeys.context)
            return
        }
        if let data = try? JSONEncoder().encode(PersistedContext(userId: userId, attributes: attributes)) {
            defaults.set(data, forKey: StorageKeys.context)
        }
    }

    // MARK: - Lock helper

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

struct PersistedContext: Codable {
    var userId: String?
    var attributes: [String: RiviumJSON]
}
