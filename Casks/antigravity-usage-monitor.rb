cask "antigravity-usage-monitor" do
  version "0.1.3"
  sha256 "468badb8e0672c375e900d6c13c16c9c047c632641059d365ca7d47e8cafed80"

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
