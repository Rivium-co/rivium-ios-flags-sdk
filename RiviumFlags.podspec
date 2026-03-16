Pod::Spec.new do |s|
  s.name             = 'RiviumFlags'
  s.version          = '0.1.0'
  s.summary          = 'Feature Flags SDK for iOS with offline caching and targeting rules'
  s.description      = 'Lightweight feature flag management for iOS with offline caching, rollout percentage targeting, user attribute targeting rules, multivariate flags, and environment overrides.'
  s.homepage         = 'https://rivium.co'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Rivium' => 'support@rivium.co' }
  s.source           = { :git => 'https://github.com/Rivium-co/rivium-ios-flags-sdk.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.osx.deployment_target = '12.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/**/*.swift'
  s.frameworks = 'Foundation', 'CryptoKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
