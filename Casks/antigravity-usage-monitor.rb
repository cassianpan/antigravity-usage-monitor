cask "antigravity-usage-monitor" do
  version "0.1.11"
  sha256 "959942b3d15e22645afe0a73e4833aef4aad8aea9d6caf744475ccd410ad9f20"

  url "https://github.com/cassianpan/antigravity-usage-monitor/releases/download/v#{version}/AntigravityUsageMonitor-#{version}-macOS-arm64.zip"
  name "Antigravity Usage Monitor"
  desc "Native macOS menu bar app for Google Antigravity quotas, cache hit rate, and token usage"
  homepage "https://github.com/cassianpan/antigravity-usage-monitor"

  depends_on macos: :sequoia
  depends_on arch: :arm64

  app "Antigravity Usage Monitor.app"

  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Antigravity Usage Monitor.app"],
                   sudo: false
  end

  caveats <<~EOS
    This app is ad-hoc self-signed (not notarized by Apple).
    Homebrew automatically cleared the quarantine attribute during installation so you can open it directly.
  EOS
end
