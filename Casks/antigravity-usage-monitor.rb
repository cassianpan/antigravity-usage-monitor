cask "antigravity-usage-monitor" do
  version "0.1.0"
  sha256 "cf68844d07fce76349f8d85c1e879cc7fa03b6dcb7fbabfc11f62d8937b3a50c"

  url "https://github.com/cassianpan/antigravity-usage-monitor/releases/download/v#{version}/AntigravityUsageMonitor-#{version}-macOS-arm64.zip"
  name "Antigravity Usage Monitor"
  desc "Native macOS menu bar app for Google Antigravity quotas, cache hit rate, and token usage"
  homepage "https://github.com/cassianpan/antigravity-usage-monitor"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "Antigravity Usage Monitor.app"

  caveats <<~EOS
    Because this app is self-signed (not notarized by Apple), if macOS blocks the first launch, run:
      xattr -dr com.apple.quarantine "/Applications/Antigravity Usage Monitor.app"
  EOS
end
