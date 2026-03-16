<p align="center">
  <a href="https://rivium.co">
    <img src="https://rivium.co/logo.png" alt="Rivium" width="120" />
  </a>
</p>

<h3 align="center">Rivium Flags iOS SDK</h3>

<p align="center">
  Feature flag management for iOS and macOS with offline caching, targeting rules, and rollout control.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white" alt="Swift 5.9+" />
  <img src="https://img.shields.io/badge/iOS-14.0+-000000?logo=apple&logoColor=white" alt="iOS 14+" />
  <img src="https://img.shields.io/badge/macOS-12.0+-000000?logo=apple&logoColor=white" alt="macOS 12+" />
  <img src="https://img.shields.io/badge/SPM-compatible-orange" alt="SPM Compatible" />
  <a href="https://cocoapods.org/pods/RiviumFlags"><img src="https://img.shields.io/cocoapods/v/RiviumFlags.svg" alt="CocoaPods" /></a>
  <img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="MIT License" />
</p>

---

## Installation

### Swift Package Manager (SPM)

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Rivium-co/rivium-ios-flags-sdk.git", from: "0.1.0")
]
```

Or in Xcode: **File > Add Package Dependencies** and enter:

```
https://github.com/Rivium-co/rivium-ios-flags-sdk.git
```

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'RiviumFlags', '~> 0.1.0'
```

Then run:

```bash
pod install
```

## Quick Start

```swift
import RiviumFlags

// Initialize
let flags = RiviumFlags(config: RiviumFlagsConfig(
    apiKey: "YOUR_API_KEY",
    environment: "production",
    enableOfflineCache: true
))

try await flags.initialize { event, data in
    print("[\(event)] \(data ?? [:])")
}

// Set user context
flags.setUserId("user-123")
flags.setUserAttributes(["plan": "pro", "country": "US"])

// Check flags
let darkMode = flags.isEnabled("dark_mode")
let variant = flags.getValue("checkout_flow")

// Full evaluation
let result = flags.evaluate("checkout_flow")
print("enabled: \(result.enabled), value: \(result.value), variant: \(result.variant)")

// Refresh from server
await flags.refresh()
```

## Features

- **Boolean & Multivariate Flags** — Simple on/off toggles or multi-variant flags with weighted distribution
- **Targeting Rules** — Target users by attributes (equals, contains, regex, in, greater_than, and more)
- **Rollout Percentages** — Gradual rollouts with deterministic MD5-based bucketing
- **Offline Caching** — Flags cached in UserDefaults for offline access
- **Environment Overrides** — Separate flag values per environment (development, staging, production)
- **Singleton Access** — Use `RiviumFlags.shared` after initialization
- **Async/Await** — Native Swift concurrency support

## Documentation

For full documentation, visit [rivium.co/docs](https://rivium.co/docs).

## License

MIT License — see [LICENSE](LICENSE) for details.
