import Foundation
import XCTest
@testable import RiviumFlags

final class ClientTests: XCTestCase {

    private func okReply(_ flags: [String: RiviumJSON], etag: String? = "\"e2-1\"") -> MockTransport.Reply {
        .init(status: 200, headers: etag.map { ["ETag": $0] } ?? [:], body: responseData(flags))
    }

    private let themeDark = flagJSON("theme", "string", enabled: true, value: "dark", variant: "dark", reason: "VARIANT", version: 3)
    private let themeLight = flagJSON("theme", "string", enabled: true, value: "light", variant: "light", reason: "VARIANT", version: 4)

    // MARK: Anonymous id

    func testAnonymousIdIsPersistedLowercaseUUIDv4() {
        let defaults = freshDefaults()
        let a = makeClient(MockTransport(), defaults: defaults)
        let id = a.anonymousId
        XCTAssertNotNil(id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression))
        XCTAssertEqual(defaults.string(forKey: "co.rivium.flags.anonymousId"), id)
        let b = makeClient(MockTransport(), defaults: defaults)
        XCTAssertEqual(b.anonymousId, id)
    }

    func testLegacyKeysRemovedAndServerSecretRefused() async {
        let defaults = freshDefaults()
        defaults.set(Data("{}".utf8), forKey: "rivium_ff_cached_flags")
        defaults.set("old", forKey: "rivium_ff_user_id")
        let t = MockTransport()
        let c = makeClient(t, defaults: defaults, apiKey: "rv_srv_secret")
        XCTAssertNil(defaults.object(forKey: "rivium_ff_cached_flags"))
        XCTAssertNil(defaults.object(forKey: "rivium_ff_user_id"))
        c.start()
        let ok = await c.refresh()
        XCTAssertFalse(ok)
        XCTAssertEqual(t.requests.count, 0, "a server secret is never sent")
    }

    func testTypeMismatchDetail() async {
        let t = MockTransport { _ in self.okReply(["theme": self.themeDark]) }
        let c = makeClient(t)
        c.start()
        _ = await c.waitUntilReady()
        let d = c.booleanDetail("theme", default: true)
        XCTAssertEqual(d.reason, .typeMismatch)
        XCTAssertTrue(d.value)
        XCTAssertFalse(d.enabled)
        XCTAssertNil(d.variant)
        c.close()
    }

    func testResetKeepsAnonymousIdAndResetAnonymousIdReplacesIt() {
        let defaults = freshDefaults()
        let c = makeClient(MockTransport(), defaults: defaults)
        let id = c.anonymousId
        c.identify("u1", attributes: ["plan": "pro"])
        c.reset()
        XCTAssertEqual(c.anonymousId, id)
        XCTAssertNil(c.currentUserId)
        XCTAssertTrue(c.currentAttributes.isEmpty)
        let fresh = c.resetAnonymousId()
        XCTAssertNotEqual(fresh, id)
        XCTAssertEqual(c.anonymousId, fresh)
        XCTAssertEqual(defaults.string(forKey: "co.rivium.flags.anonymousId"), fresh)
    }

    func testAnonymousIdSentAlsoWhenUserIdSet() async {
        let t = MockTransport { _ in .init(status: 200, body: responseData([:])) }
        let c = makeClient(t)
        c.identify("u1")
        c.start()
        _ = await c.waitUntilReady()
        let ctx = bodyJSON(t.requests[0])["context"]
        XCTAssertEqual(ctx?["userId"], "u1")
        XCTAssertEqual(ctx?["anonymousId"]?.stringValue, c.anonymousId)
        // No environment / flagKeys configured → omitted (Default layer, all flags).
        XCTAssertNil(bodyJSON(t.requests[0])["environment"])
        XCTAssertNil(bodyJSON(t.requests[0])["flagKeys"])
    }

    // MARK: Getters

    func testNotReadyAndFlagNotFound() async {
        let t = MockTransport { _ in self.okReply(["theme": self.themeDark]) }
        let c = makeClient(t)
        XCTAssertFalse(c.isReady)
        XCTAssertEqual(c.stringDetail("theme", default: "x").reason, .notReady)
        XCTAssertEqual(c.getString("theme", default: "x"), "x")
        XCTAssertTrue(c.isEnabled("theme", default: true))
        c.start()
        let ready = await c.waitUntilReady()
        XCTAssertTrue(ready)
        XCTAssertEqual(c.getString("theme", default: "x"), "dark")
        XCTAssertEqual(c.stringDetail("nope", default: "x").reason, .flagNotFound)
        XCTAssertEqual(c.getAll().keys.sorted(), ["theme"])
    }

    func testJsonDecodable() async {
        struct Layout: Decodable, Equatable { let columns: Int; let style: String }
        let t = MockTransport { _ in self.okReply([
            "layout": flagJSON("layout", "json", enabled: true, value: ["columns": 3, "style": "grid"], variant: "a", reason: "VARIANT"),
        ]) }
        let c = makeClient(t)
        c.start()
        _ = await c.waitUntilReady()
        XCTAssertEqual(c.getJson("layout", as: Layout.self, default: Layout(columns: 1, style: "list")), Layout(columns: 3, style: "grid"))
        XCTAssertEqual(c.getJson("missing", as: Layout.self, default: Layout(columns: 1, style: "list")), Layout(columns: 1, style: "list"))
    }

    // MARK: Cache and ETag

    func testCacheServedAtStartAndScopedToKeyEnvironmentAndUser() async {
        let defaults = freshDefaults()
        let t = MockTransport { _ in self.okReply(["theme": self.themeDark]) }
        let a = makeClient(t, defaults: defaults, environment: "production")
        a.identify("u1", attributes: ["plan": "pro"])
        a.start()
        _ = await a.waitUntilReady()
        a.close()

        // Same key + environment: served before the network answers, context restored.
        let offline = MockTransport { _ in .init(networkError: true) }
        let b = makeClient(offline, defaults: defaults, environment: "production")
        XCTAssertTrue(b.isReady)
        XCTAssertEqual(b.getString("theme", default: "x"), "dark")
        XCTAssertEqual(b.currentUserId, "u1")
        XCTAssertEqual(b.currentAttributes["plan"], "pro")
        b.start()
        _ = await waitUntil { offline.requests.count >= 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(b.getString("theme", default: "x"), "dark", "never clear the cache on failure")
        b.close()

        XCTAssertFalse(makeClient(offline, defaults: defaults, environment: "staging").isReady)
        XCTAssertFalse(makeClient(offline, defaults: defaults, apiKey: "rv_test_other", environment: "production").isReady)
    }

    func testCacheNeverStoresApiKey() async {
        let defaults = freshDefaults()
        let t = MockTransport { _ in self.okReply(["theme": self.themeDark]) }
        let c = makeClient(t, defaults: defaults, apiKey: "rv_live_secretvalue123")
        c.start()
        _ = await c.waitUntilReady()
        let data = defaults.data(forKey: "rivium_flags_cache_v2")!
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("rv_live_secretvalue123"))
    }

    func testIfNoneMatchOnlyForSameContextAnd304KeepsResults() async {
        let t = MockTransport { req in
            if req.value(forHTTPHeaderField: "If-None-Match") == "\"e2-1\"" { return .init(status: 304, headers: ["ETag": "\"e2-1\""]) }
            return self.okReply(["theme": self.themeDark])
        }
        let c = makeClient(t)
        c.start()
        _ = await c.waitUntilReady()
        XCTAssertNil(t.requests[0].value(forHTTPHeaderField: "If-None-Match"))

        let ok = await c.refresh()
        XCTAssertTrue(ok)
        XCTAssertEqual(t.requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"e2-1\"")
        XCTAssertEqual(c.getString("theme", default: "x"), "dark")

        c.setAttributes(["plan": "pro"])
        _ = await waitUntil { t.requests.count >= 3 }
        XCTAssertNil(t.requests[2].value(forHTTPHeaderField: "If-None-Match"), "context changed: no ETag")
        c.close()
    }

    func testUserChangeDropsCacheImmediately() async {
        let t = MockTransport { req in
            bodyJSON(req)["context"]?["userId"] == "u2"
                ? self.okReply(["theme": self.themeLight], etag: "\"e2-2\"")
                : self.okReply(["theme": self.themeDark])
        }
        let c = makeClient(t)
        c.identify("u1")
        c.start()
        _ = await c.waitUntilReady()
        XCTAssertEqual(c.getString("theme", default: "x"), "dark")
        c.identify("u2")
        XCTAssertFalse(c.isReady, "previous user's results must not be served")
        XCTAssertEqual(c.stringDetail("theme", default: "x").reason, .notReady)
        _ = await c.waitUntilReady()
        XCTAssertEqual(c.getString("theme", default: "x"), "light")

        // Attribute change for the same user keeps serving the current results meanwhile.
        c.setAttributes(["plan": "pro"])
        XCTAssertTrue(c.isReady)
        c.close()
    }

    func testIdentifyIsDebouncedAndSameContextDoesNotRefetch() async {
        let t = MockTransport { _ in self.okReply(["theme": self.themeDark]) }
        let c = makeClient(t)
        c.start()
        _ = await c.waitUntilReady()
        _ = await waitUntil { t.requests.count == 1 }
        c.setAttributes(["a": 1])
        c.setAttributes(["a": 2])
        c.setAttributes(["a": 3])
        _ = await waitUntil { t.requests.count >= 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(bodyJSON(t.requests[1])["context"]?["attributes"]?["a"], 3)
        c.setAttributes(["a": 3])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.requests.count, 2)
        c.close()
    }

    func testNewerRequestSupersedesOlder() async {
        let t = MockTransport { req in
            bodyJSON(req)["context"]?["userId"] == "slow"
                ? .init(status: 200, body: responseData(["theme": self.themeDark]), delay: 0.3)
                : self.okReply(["theme": self.themeLight])
        }
        let c = makeClient(t)
        c.identify("slow")
        async let first = c.refresh()
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.identify("fast")
        let second = await c.refresh()
        let firstOk = await first
        XCTAssertTrue(second)
        XCTAssertFalse(firstOk)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(c.getString("theme", default: "x"), "light", "last write wins")
    }

    // MARK: Errors

    func test401StopsAutomaticFetchesUntilRefresh() async {
        let t = MockTransport { _ in .init(status: 401, body: Data(#"{"statusCode":401,"message":"Invalid API key"}"#.utf8)) }
        let c = makeClient(t)
        let box = EventBox()
        c.addListener { box.add($0) }
        c.start()
        _ = await waitUntil { t.requests.count == 1 }
        _ = await waitUntil { box.errors.count == 1 }
        XCTAssertEqual(box.errors.first?.kind, .unauthorized)
        c.setAttributes(["plan": "pro"])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.requests.count, 1, "no automatic retry after 401")
        _ = await c.refresh()
        XCTAssertEqual(t.requests.count, 2, "refresh() resumes")
        c.close()
    }

    func test404And403AreReportedAndNotRetried() async {
        for (status, kind) in [(404, RiviumFlagsError.Kind.environmentNotFound), (403, .forbidden)] {
            let t = MockTransport { _ in
                .init(status: status, body: Data(#"{"statusCode":\#(status),"code":"environment_not_found","message":"nope"}"#.utf8))
            }
            let c = makeClient(t, environment: "nope")
            let box = EventBox()
            c.addListener { box.add($0) }
            c.start()
            _ = await waitUntil { box.errors.count == 1 }
            XCTAssertEqual(box.errors.first?.kind, kind)
            XCTAssertEqual(box.errors.first?.statusCode, status)
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(t.requests.count, 1)
            c.close()
        }
    }

    func test400SameBodyNotRetriedAutomatically() async {
        let t = MockTransport { _ in .init(status: 400, body: Data(#"{"statusCode":400,"code":"invalid_request","message":"bad"}"#.utf8)) }
        let c = makeClient(t)
        c.start()
        _ = await waitUntil { t.requests.count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.didEnterForeground()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.requests.count, 1)
        c.setAttributes(["x": 1])
        _ = await waitUntil { t.requests.count == 2 }
        XCTAssertEqual(t.requests.count, 2, "a different body is sent")
        c.close()
    }

    func test429RetriesAfterRetryAfterAnd5xxKeepsCache() async {
        var calls = 0
        let lock = NSLock()
        let t = MockTransport { _ in
            lock.lock(); calls += 1; let n = calls; lock.unlock()
            switch n {
            case 1: return .init(status: 429, headers: ["Retry-After": "0"])
            case 2: return self.okReply(["theme": self.themeDark])
            default: return .init(status: 503)
            }
        }
        let c = makeClient(t, random: { 0 })
        let box = EventBox()
        c.addListener { box.add($0) }
        c.start()
        let ready = await c.waitUntilReady(timeout: 3)
        XCTAssertTrue(ready, "retried after Retry-After")
        XCTAssertEqual(t.requests.count, 2)
        _ = await waitUntil { box.errors.contains { $0.kind == .rateLimited } }

        let ok = await c.refresh()
        XCTAssertFalse(ok)
        XCTAssertEqual(c.getString("theme", default: "x"), "dark", "5xx keeps serving the cache")
        _ = await waitUntil { box.errors.contains { $0.kind == .server } }
        c.close()
    }

    func testBackoffSchedule() {
        // 429 with Retry-After 7: first wait is never shorter than 7 s, then ×2, capped at 5 min, ±20 % jitter.
        XCTAssertEqual(Backoff.delay(attempt: 0, retryAfter: 7, random: 0), 7)
        XCTAssertEqual(Backoff.delay(attempt: 0, retryAfter: 7, random: 1), 8.4, accuracy: 0.0001)
        XCTAssertEqual(Backoff.delay(attempt: 1, retryAfter: 7, random: 0.5), 14)
        XCTAssertEqual(Backoff.delay(attempt: 0, retryAfter: nil, random: 0.5), 5)
        XCTAssertEqual(Backoff.delay(attempt: 3, retryAfter: nil, random: 0.5), 40)
        XCTAssertEqual(Backoff.delay(attempt: 10, retryAfter: nil, random: 0.5), 300)
        XCTAssertEqual(Backoff.delay(attempt: 10, retryAfter: nil, random: 1), 300, "never above 5 min")
        XCTAssertEqual(Backoff.delay(attempt: 10, retryAfter: nil, random: 0), 240)
        XCTAssertEqual(Backoff.parseRetryAfter("12"), 12)
        XCTAssertEqual(Backoff.parseRetryAfter(nil), 5)
        XCTAssertEqual(Backoff.parseRetryAfter("garbage"), 5)
    }

    // MARK: Attributes and events

    func testAttributeSanitizing() {
        let c = makeClient(MockTransport())
        c.setAttributes([
            "plan": "pro", "age": 31, "beta": true, "tags": ["a", 1, NSNull()], "none": NSNull(),
            "nested": ["a": 1], "userId": "spoof", "anonymousId": "spoof", "long": String(repeating: "x", count: 1025),
            "nan": Double.nan,
        ])
        XCTAssertEqual(c.currentAttributes, ["plan": "pro", "age": 31, "beta": true, "tags": ["a", 1, nil], "none": nil])
    }

    func testReadyAndUpdatedEventsOnCallbackQueue() async {
        let t = MockTransport { req in
            bodyJSON(req)["context"]?["attributes"]?["v"] == 2
                ? self.okReply(["theme": self.themeLight], etag: "\"e2-2\"")
                : self.okReply(["theme": self.themeDark])
        }
        let c = makeClient(t)
        let box = EventBox()
        c.addListener { box.add($0) }
        c.start()
        _ = await waitUntil { box.events.count >= 2 }
        XCTAssertEqual(box.readyCount, 1)
        c.setAttributes(["v": 2])
        _ = await waitUntil { box.events.count >= 3 }
        if case .updated(let keys) = box.events.last { XCTAssertEqual(keys, ["theme"]) } else { XCTFail("expected updated") }
        XCTAssertEqual(box.readyCount, 1, "ready fires once")
        c.close()
    }

    func testPollingIntervalClamp() {
        XCTAssertEqual(RiviumFlagsConfig(apiKey: "k").effectivePollInterval, 0)
        XCTAssertEqual(RiviumFlagsConfig(apiKey: "k", refreshIntervalSeconds: 10).effectivePollInterval, 60)
        XCTAssertEqual(RiviumFlagsConfig(apiKey: "k", refreshIntervalSeconds: 120).effectivePollInterval, 120)
    }

    func testForegroundRefetchOnlyWhenStale() async {
        let t = MockTransport { _ in self.okReply(["theme": self.themeDark]) }
        let c = makeClient(t)
        c.start()
        _ = await c.waitUntilReady()
        _ = await waitUntil { t.requests.count == 1 }
        c.didEnterBackground()
        c.didEnterForeground()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(t.requests.count, 1, "fresh results: no refetch on foreground")
        c.close()
    }
}
