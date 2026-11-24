cask "antigravity-usage-monitor" do
  version "0.1.6"
  sha256 "51642a83b2c449666a11cfb80e361387fe641425b02e22d120e5a1eb89578cbd"

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
