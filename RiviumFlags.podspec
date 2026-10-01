Pod::Spec.new do |s|
  s.name             = 'RiviumFlags'
  s.version          = '0.2.0'
  s.summary          = 'Rivium Flags client SDK for iOS and macOS: server-evaluated feature flags with offline cache'
  s.description      = 'Rivium Flags client for iOS and macOS. Flags are evaluated on the Rivium Flags server for the current user context; the SDK caches the results on the device, serves them offline and exposes typed getters with reasons. No targeting rules are shipped to the app.'
  s.homepage         = 'https://rivium.co'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Rivium' => 'support@rivium.co' }
  s.source           = { :git => 'https://github.com/Rivium-co/rivium-ios-flags-sdk.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '14.0'
  s.osx.deployment_target = '12.0'
  s.swift_version = '5.9'

  s.source_files = 'Sources/**/*.swift'
  s.frameworks = 'Foundation', 'CryptoKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
