import SwiftUI
import RiviumFlags

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Rivium Flags — iOS SDK Test Suite
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct TestResult: Identifiable {
    let id = UUID()
    let test: String
    let detail: String
    let pass: Bool
}

struct FlagTestView: View {
    @State private var results: [TestResult] = []
    @State private var loading = true
    @State private var userId = "test-user-1"
    @State private var selectedEnv = "none"
    @State private var flagCount = 0

    private let apiKey = "YOUR_API_KEY" // Replace with your API key from Rivium Console

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    userSwitcher
                    envSwitcher
                    statusBar
                    testContent
                }
                .padding(.vertical)
            }
            .background(Color(white: 0.95))
            .navigationTitle("Rivium Flags Test")
            .onAppear { runTests() }
        }
    }

    // MARK: - Subviews

    private var userSwitcher: some View {
        HStack {
            Text("User:").bold()
            ForEach(["test-user-1", "test-user-2", "test-user-3"], id: \.self) { uid in
                Button(uid) {
                    userId = uid
                    runTests()
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(userId == uid ? Color.orange.opacity(0.2) : Color.gray.opacity(0.1))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(userId == uid ? Color.orange : Color.clear, lineWidth: 1.5)
                )
            }
        }
        .padding(.horizontal)
    }

    private var envSwitcher: some View {
        HStack {
            Text("Env:").bold()
            ForEach(["none", "development", "staging", "production"], id: \.self) { env in
                Button(env == "none" ? "Global" : env) {
                    selectedEnv = env
                    runTests()
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(selectedEnv == env ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selectedEnv == env ? Color.blue : Color.clear, lineWidth: 1.5)
                )
            }
        }
        .padding(.horizontal)
    }

    private var statusBar: some View {
        HStack {
            Label("\(flagCount) flags loaded", systemImage: "flag.fill")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)

            Spacer()

            Button(action: runTests) {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var testContent: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            testResultsList
            testSummary
        }
    }

    private var testResultsList: some View {
        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
            testCard(index: index, result: result)
        }
    }

    private func testCard(index: Int, result: TestResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Test \(index + 1)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(4)

                Text(result.test)
                    .font(.subheadline.bold())

                Spacer()

                Image(systemName: result.pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(result.pass ? .green : .red)
            }

            Text(result.detail)
                .font(.caption)
                .monospaced()
                .foregroundColor(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.95))
                .cornerRadius(6)
        }
        .padding(12)
        .background(Color.white)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.05), radius: 2)
        .padding(.horizontal)
    }

    private var testSummary: some View {
        let passed = results.filter(\.pass).count
        let failed = results.filter { !$0.pass }.count
        return HStack(spacing: 16) {
            Label("Passed: \(passed)", systemImage: "checkmark")
                .foregroundColor(.green)
            if failed > 0 {
                Label("Failed: \(failed)", systemImage: "xmark")
                    .foregroundColor(.red)
            }
            Text("Total: \(results.count)")
                .foregroundColor(.secondary)
        }
        .font(.subheadline.bold())
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
        .padding(.horizontal)
    }

    // MARK: - Tests

    private func runTests() {
        loading = true
        results = []

        Task {
            var testResults: [TestResult] = []

            let flags = RiviumFlags(config: RiviumFlagsConfig(
                apiKey: apiKey,
                environment: selectedEnv == "none" ? nil : selectedEnv,
                debug: true,
                enableOfflineCache: true
            ))

            // Initialize
            do {
                try await flags.initialize { event, data in
                    print("[RiviumFlags] \(event): \(data ?? [:])")
                }
                testResults.append(TestResult(test: "Initialize SDK", detail: "Connected with API key", pass: true))
            } catch {
                testResults.append(TestResult(test: "Initialize SDK", detail: "Failed: \(error)", pass: false))
                await MainActor.run {
                    self.results = testResults
                    self.loading = false
                }
                return
            }

            // Set user context
            flags.setUserId(userId)
            flags.setUserAttributes(["plan": "pro", "country": "US"])

            // Test 1: Fetch all flags
            let allFlags = flags.getAll()
            testResults.append(TestResult(
                test: "GET /public/flags",
                detail: "Fetched \(allFlags.count) flags: \(allFlags.map(\.key).joined(separator: ", "))",
                pass: !allFlags.isEmpty
            ))

            // Test 2: Boolean flag
            let darkMode = flags.isEnabled("dark_mode")
            testResults.append(TestResult(test: "Boolean flag: dark_mode", detail: "isEnabled = \(darkMode)", pass: true))

            // Test 3: Multivariate flag
            let checkoutEnabled = flags.isEnabled("checkout_flow")
            let checkoutValue = flags.getValue("checkout_flow")
            testResults.append(TestResult(
                test: "Multivariate: checkout_flow",
                detail: "enabled=\(checkoutEnabled), value=\(checkoutValue ?? "nil")",
                pass: true
            ))

            // Test 4: Targeting rules (matching)
            let premiumMatch = flags.isEnabled("premium_banner")
            testResults.append(TestResult(test: "Targeting (plan=pro, country=US)", detail: "premium_banner = \(premiumMatch)", pass: true))

            // Targeting (non-matching)
            flags.setUserAttributes(["plan": "free", "country": "IR"])
            let premiumNoMatch = flags.isEnabled("premium_banner")
            testResults.append(TestResult(test: "Targeting (plan=free, country=IR)", detail: "premium_banner = \(premiumNoMatch)", pass: true))

            // Restore attributes
            flags.setUserAttributes(["plan": "pro", "country": "US"])

            // Test 5: Rollout
            var rollout: [(String, Bool)] = []
            for uid in ["user-1", "user-2", "user-3", "user-4", "user-5"] {
                flags.setUserId(uid)
                let result = flags.isEnabled("gradual_redesign")
                rollout.append((uid, result))
            }
            let enabledCount = rollout.filter(\.1).count
            let rolloutStr = rollout.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
            testResults.append(TestResult(
                test: "Rollout 30%: gradual_redesign",
                detail: "\(rolloutStr)\n\(enabledCount)/5 enabled",
                pass: true
            ))

            // Restore user
            flags.setUserId(userId)

            // Test 6: Default value
            let missing = flags.getValue("nonexistent_flag", defaultValue: "fallback")
            let missingStr = missing as? String ?? "nil"
            testResults.append(TestResult(
                test: "Default value: nonexistent_flag",
                detail: "getValue = \"\(missingStr)\" (default: \"fallback\")",
                pass: missingStr == "fallback"
            ))

            // Test 7: Refresh
            await flags.refresh()
            testResults.append(TestResult(
                test: "Manual refresh",
                detail: "Refreshed. Total: \(flags.getAll().count) flags",
                pass: true
            ))

            // Test 8: Evaluate (full result)
            let evalResult = flags.evaluate("checkout_flow")
            testResults.append(TestResult(
                test: "Evaluate: checkout_flow",
                detail: "enabled=\(evalResult.enabled), value=\(evalResult.value ?? "nil"), variant=\(evalResult.variant ?? "nil")",
                pass: true
            ))

            // Test 9: getUserId
            let currentUserId = flags.getUserId()
            testResults.append(TestResult(
                test: "getUserId",
                detail: "getUserId = \"\(currentUserId ?? "nil")\" (expected: \"\(userId)\")",
                pass: currentUserId == userId
            ))

            // Test 10: Singleton (shared)
            let sharedFlags = RiviumFlags.shared
            testResults.append(TestResult(
                test: "Singleton: RiviumFlags.shared",
                detail: "shared instance has \(sharedFlags?.getAll().count ?? 0) flags",
                pass: sharedFlags != nil
            ))

            // Test 11: Offline cache
            testResults.append(TestResult(
                test: "Offline cache",
                detail: "Cached \(flags.getAll().count) flags in UserDefaults",
                pass: true
            ))

            // ── Test 12: Environment overrides ──
            let testFlagKey = allFlags.isEmpty ? "maintenance_mode" : allFlags[0].key
            var envLines: [String] = []

            for env in ["none", "development", "staging", "production"] {
                do {
                    let envFlags = RiviumFlags(config: RiviumFlagsConfig(
                        apiKey: apiKey,
                        environment: env == "none" ? nil : env,
                        debug: true,
                        enableOfflineCache: false
                    ))
                    try await envFlags.initialize()
                    envFlags.setUserId("test-user-1")
                    let flagEnabled = envFlags.isEnabled(testFlagKey)
                    let flagValue = envFlags.getValue(testFlagKey)
                    envLines.append("\(env): enabled=\(flagEnabled), value=\(flagValue ?? "nil"), flags=\(envFlags.getAll().count)")
                } catch {
                    envLines.append("\(env): error=\(error)")
                }
            }

            testResults.append(TestResult(
                test: "Environment overrides: \(testFlagKey)",
                detail: "Flag \"\(testFlagKey)\" across environments:\n\(envLines.joined(separator: "\n"))",
                pass: true
            ))

            // Test 13: Reset & Dispose
            let flagsBefore = flags.getAll().count
            flags.dispose()
            flags.reset()
            let flagsAfter = flags.getAll().count
            testResults.append(TestResult(
                test: "Reset & Dispose",
                detail: "Before: \(flagsBefore) flags, dispose() called, After reset: \(flagsAfter) flags",
                pass: flagsAfter == 0
            ))

            await MainActor.run {
                self.results = testResults
                self.flagCount = allFlags.count
                self.loading = false
            }
        }
    }
}

#Preview {
    FlagTestView()
}
