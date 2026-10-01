import SwiftUI
import RiviumFlags

// Rivium Flags — iOS example (SDK 0.2.0)
//
// Put your public project key below (Rivium Console → Flags → SDK keys). Never put a server secret in an app.

@MainActor
final class FlagsModel: ObservableObject {
    let flags = RiviumFlags(config: RiviumFlagsConfig(
        apiKey: "YOUR_API_KEY",
        environment: "production",
        debug: true
    ))

    @Published var results: [FlagResult] = []
    @Published var lastEvent = "starting…"
    @Published var userId: String?
    private var token: RiviumFlagsListenerToken?

    init() {
        token = flags.addListener { [weak self] event in
            // Delivered on the main thread.
            guard let self else { return }
            switch event {
            case .ready: self.lastEvent = "ready"
            case .updated(let keys): self.lastEvent = "updated: \(keys.sorted().joined(separator: ", "))"
            case .error(let error): self.lastEvent = error.description
            }
            self.reload()
        }
        flags.start()
        reload()
    }

    func reload() {
        results = flags.getAll().values.sorted { $0.key < $1.key }
        userId = flags.currentUserId
    }

    func signIn(_ id: String) { flags.identify(id, attributes: ["plan": "pro", "country": "AM"]) }
    func signOut() { flags.reset(); reload() }
    func refresh() { flags.refresh { [weak self] _ in self?.reload() } }
}

struct FlagTestView: View {
    @StateObject private var model = FlagsModel()

    var body: some View {
        NavigationView {
            List {
                Section("Context") {
                    LabeledContent("User", value: model.userId ?? "signed out")
                    LabeledContent("Anonymous id", value: String(model.flags.anonymousId.prefix(8)) + "…")
                    LabeledContent("Last event", value: model.lastEvent)
                    HStack {
                        ForEach(["user-1", "user-2"], id: \.self) { id in
                            Button(id) { model.signIn(id) }.buttonStyle(.bordered)
                        }
                        Button("Sign out") { model.signOut() }.buttonStyle(.bordered)
                    }
                }
                Section("Typed getters") {
                    LabeledContent("isEnabled(new-checkout)", value: "\(model.flags.isEnabled("new-checkout"))")
                    LabeledContent("getString(theme)", value: model.flags.getString("theme", default: "light"))
                    let d = model.flags.stringDetail("theme", default: "light")
                    LabeledContent("theme reason", value: d.reason.rawValue)
                }
                Section("All results (\(model.results.count))") {
                    ForEach(model.results, id: \.key) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.key).font(.headline)
                            Text("\(r.valueType) · \(r.enabled ? "on" : "off") · \(r.reason.rawValue)\(r.variant.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Rivium Flags")
            .toolbar { Button("Refresh") { model.refresh() } }
            .refreshable { _ = await model.flags.refresh(); model.reload() }
        }
    }
}
