import Foundation
import XCTest
@testable import RiviumFlags

/// Runs every case of docs/sdk-test-vectors.json through the client SDK: request building (context, anonymous id,
/// headers), response parsing, typed getters, reasons. Hash vectors do not apply: client SDKs never bucket.
final class VectorTests: XCTestCase {

    struct Case { let suite: String; let name: String; let flag: RiviumJSON; let context: RiviumJSON; let expected: RiviumJSON }

    static func loadCases() throws -> (cases: [Case], hashVectors: Int) {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sdk-test-vectors", withExtension: "json"))
        let root = try JSONDecoder().decode(RiviumJSON.self, from: Data(contentsOf: url))
        XCTAssertEqual(root["schemaVersion"], 2)
        var out: [Case] = []
        for suite in root["suites"]?.arrayValue ?? [] {
            let flags = suite["flags"]?.arrayValue ?? []
            for c in suite["cases"]?.arrayValue ?? [] {
                let key = c["flagKey"]?.stringValue ?? ""
                let flag = try XCTUnwrap(flags.first { $0["key"]?.stringValue == key }, "flag \(key)")
                out.append(Case(suite: suite["name"]?.stringValue ?? "", name: c["name"]?.stringValue ?? "",
                                flag: flag, context: c["context"] ?? [:], expected: c["expected"] ?? [:]))
            }
        }
        return (out, root["hashVectors"]?.arrayValue?.count ?? 0)
    }

    func testAllVectorCases() async throws {
        let (cases, _) = try Self.loadCases()
        XCTAssertEqual(cases.count, 171, "vector file changed: update the expected count")
        var passed = 0

        for c in cases {
            let label = "[\(c.suite)] \(c.name)"
            let key = c.flag["key"]!.stringValue!
            let valueType = c.flag["valueType"]!.stringValue!
            let exp = c.expected
            let version = c.flag["version"]?.intValue ?? 1

            let transport = MockTransport { _ in
                .init(status: 200, headers: ["ETag": "\"e2-test\""], body: responseData([
                    key: flagJSON(key, valueType, enabled: exp["enabled"]!.boolValue!, value: exp["value"]!,
                                  variant: exp["variant"]?.stringValue, reason: exp["reason"]!.stringValue!, version: version),
                ], environment: "production"))
            }
            let defaults = freshDefaults()
            let failuresBefore = testRun?.failureCount ?? 0
            // Empty ids are "no id": never sent; an empty stored anonymous id is replaced.
            let userId = c.context["userId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            let presetAnon = c.context["anonymousId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            if let anon = presetAnon {
                defaults.set(anon, forKey: "co.rivium.flags.anonymousId")
            }
            let client = makeClient(transport, defaults: defaults, environment: "production", flagKeys: [key])

            // Not ready before any result.
            XCTAssertEqual(client.getDetail(key).reason, .notReady, label)

            let attrs = (c.context["attributes"]?.objectValue ?? [:]).mapValues { $0.anyValue }
            client.identify(userId, attributes: attrs)
            client.start()
            let ready = await client.waitUntilReady(timeout: 3)
            XCTAssertTrue(ready, label)

            // --- request ---
            let req = try XCTUnwrap(transport.requests.first, label)
            XCTAssertEqual(req.httpMethod, "POST", label)
            XCTAssertEqual(req.url?.absoluteString, "https://flags.rivium.co/public/v2/evaluate", label)
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "rv_test_key", label)
            XCTAssertEqual(req.value(forHTTPHeaderField: "x-rivium-sdk"), "ios/0.2.0", label)
            XCTAssertEqual(req.value(forHTTPHeaderField: "content-type"), "application/json", label)
            XCTAssertNil(req.value(forHTTPHeaderField: "If-None-Match"), label)
            XCTAssertNil(req.value(forHTTPHeaderField: "x-server-secret"), label)
            let body = bodyJSON(req)
            XCTAssertEqual(body["environment"], "production", label)
            XCTAssertEqual(body["flagKeys"], .array([.string(key)]), label)
            XCTAssertEqual(body["context"]?["userId"]?.stringValue, userId, label)
            // Client SDKs always send their persisted anonymous id.
            XCTAssertEqual(body["context"]?["anonymousId"]?.stringValue, client.anonymousId, label)
            if let anon = presetAnon { XCTAssertEqual(client.anonymousId, anon, label) }
            var expectedAttrs = c.context["attributes"]?.objectValue ?? [:]
            expectedAttrs.removeValue(forKey: "userId")
            expectedAttrs.removeValue(forKey: "anonymousId")
            XCTAssertEqual(body["context"]?["attributes"], .object(expectedAttrs), label)
            XCTAssertEqual(Set(body.objectValue?.keys.map { $0 } ?? []), ["environment", "context", "flagKeys"], label)

            // --- results ---
            let d = client.getDetail(key)
            XCTAssertEqual(d.enabled, exp["enabled"]?.boolValue, label)
            XCTAssertEqual(d.value, exp["value"], label)
            XCTAssertEqual(d.variant, exp["variant"]?.stringValue, label)
            XCTAssertEqual(d.reason.rawValue, exp["reason"]?.stringValue, label)
            XCTAssertEqual(d.version, version, label)
            XCTAssertEqual(client.isEnabled(key, default: !(exp["enabled"]!.boolValue!)), exp["enabled"]!.boolValue!, label)

            // Typed getter of the flag's own type returns the served value; the others TYPE_MISMATCH + default.
            let value = exp["value"]!
            switch valueType {
            case "boolean":
                if let b = value.boolValue { XCTAssertEqual(client.booleanDetail(key, default: !b).value, b, label) }
                XCTAssertEqual(client.stringDetail(key, default: "dflt").reason, .typeMismatch, label)
                XCTAssertEqual(client.getString(key, default: "dflt"), "dflt", label)
            case "string":
                let sd = client.stringDetail(key, default: "dflt")
                XCTAssertEqual(sd.value, value.stringValue ?? "dflt", label)
                XCTAssertEqual(sd.reason.rawValue, exp["reason"]?.stringValue, label)
                XCTAssertEqual(client.booleanDetail(key, default: true).reason, .typeMismatch, label)
                XCTAssertTrue(client.getBoolean(key, default: true), label)
            case "number":
                XCTAssertEqual(client.getNumber(key, default: -1), value.numberValue ?? -1, label)
                XCTAssertEqual(client.jsonDetail(key, default: nil).reason, .typeMismatch, label)
            case "json":
                XCTAssertEqual(client.getJson(key, default: "dflt"), value, label)
                XCTAssertEqual(client.numberDetail(key, default: 7).reason, .typeMismatch, label)
                XCTAssertEqual(client.getNumber(key, default: 7), 7, label)
            default:
                XCTFail("unknown valueType \(valueType)")
            }

            // Unknown key → FLAG_NOT_FOUND with the code default.
            let missing = client.stringDetail("__missing__", default: "code")
            XCTAssertEqual(missing.reason, .flagNotFound, label)
            XCTAssertEqual(missing.value, "code", label)
            XCTAssertFalse(missing.enabled, label)

            client.close()
            if (testRun?.failureCount ?? 0) == failuresBefore { passed += 1 }
        }
        XCTAssertEqual(passed, 171)
        print("Rivium Flags vectors: \(passed)/\(cases.count) client cases passed")
    }

    func testHashVectorsAreNotUsedByClientSDK() throws {
        // Client SDKs never compute buckets (evaluation happens on the server); the 7 hash vectors only
        // apply to server SDKs. This test only checks the file still has them so the count in reports is right.
        let (_, hashCount) = try Self.loadCases()
        XCTAssertEqual(hashCount, 7)
    }
}
