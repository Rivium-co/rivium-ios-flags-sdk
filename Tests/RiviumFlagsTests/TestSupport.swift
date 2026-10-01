import Foundation
import XCTest
@testable import RiviumFlags

/// Scripted transport: records every request and answers with `handler`.
final class MockTransport: FlagsTransport, @unchecked Sendable {
    struct Reply {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var delay: TimeInterval = 0
        var networkError = false
    }

    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _handler: (URLRequest) -> Reply

    init(_ handler: @escaping (URLRequest) -> Reply = { _ in Reply(status: 200, body: Data(#"{"flags":{}}"#.utf8)) }) {
        _handler = handler
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func record(_ request: URLRequest) -> (URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return _handler
    }

    func setHandler(_ h: @escaping (URLRequest) -> Reply) { lock.lock(); _handler = h; lock.unlock() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let h = record(request)
        let reply = h(request)
        if reply.delay > 0 { try await Task.sleep(nanoseconds: UInt64(reply.delay * 1_000_000_000)) }
        if reply.networkError { throw URLError(.notConnectedToInternet) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, resp)
    }
}

func bodyJSON(_ request: URLRequest) -> RiviumJSON {
    guard let data = request.httpBody, let j = try? JSONDecoder().decode(RiviumJSON.self, from: data) else { return .null }
    return j
}

func responseData(_ flags: [String: RiviumJSON], environment: RiviumJSON = .null) -> Data {
    let root: RiviumJSON = .object([
        "environment": environment,
        "evaluatedAt": "2026-10-01T12:00:00.000Z",
        "flags": .object(flags),
    ])
    return try! JSONEncoder().encode(root)
}

func flagJSON(_ key: String, _ type: String, enabled: Bool, value: RiviumJSON, variant: String? = nil,
              reason: String, version: Int = 1) -> RiviumJSON {
    .object([
        "key": .string(key), "valueType": .string(type), "enabled": .bool(enabled), "value": value,
        "variant": variant.map { .string($0) } ?? .null, "reason": .string(reason), "version": .number(Double(version)),
    ])
}

func freshDefaults() -> UserDefaults {
    let name = "rivium-flags-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

func makeClient(
    _ transport: MockTransport,
    defaults: UserDefaults = freshDefaults(),
    apiKey: String = "rv_test_key",
    environment: String? = nil,
    flagKeys: [String]? = nil,
    cacheEnabled: Bool = true,
    random: @escaping @Sendable () -> Double = { 0.5 }
) -> RiviumFlags {
    RiviumFlags(
        config: RiviumFlagsConfig(apiKey: apiKey, environment: environment, flagKeys: flagKeys, cacheEnabled: cacheEnabled),
        transport: transport,
        defaults: defaults,
        callbackQueue: DispatchQueue(label: "rivium-flags-tests-callbacks"),
        debounceInterval: 0.01,
        random: random
    )
}

/// Polls `condition` until true or timeout.
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Thread-safe event recorder for listeners.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RiviumFlagsEvent] = []
    func add(_ e: RiviumFlagsEvent) { lock.lock(); _events.append(e); lock.unlock() }
    var events: [RiviumFlagsEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    var errors: [RiviumFlagsError] { events.compactMap { if case .error(let e) = $0 { return e }; return nil } }
    var readyCount: Int { events.filter { if case .ready = $0 { return true }; return false }.count }
}
