#!/usr/bin/env bash
# Generate bilingual GitHub Release notes from CHANGELOG.zh-CN.md + CHANGELOG.md + install instructions.
# Usage: Scripts/release-notes.sh <version> [zip_sha256]
set -euo pipefail

VERSION="${1:?usage: Scripts/release-notes.sh <version> [zip_sha256]}"
VERSION="${VERSION#v}"
SHA="${2:-}"
cd "$(dirname "$0")/.."

extract_section() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v v="$VERSION" '
    /^## / { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
    found { print }
  ' "$file" | sed -e '/./,$!d'
}

zh_section="$(extract_section CHANGELOG.zh-CN.md)"
en_section="$(extract_section CHANGELOG.md)"

if [ -z "$zh_section" ] && [ -z "$en_section" ]; then
  echo "Neither CHANGELOG.md nor CHANGELOG.zh-CN.md has a section for $VERSION" >&2
  exit 1
fi

if [ -n "$zh_section" ]; then
  printf '## 更新内容\n\n%s\n' "$zh_section"
fi

if [ -n "$en_section" ]; then
  if [ -n "$zh_section" ]; then
    printf '\n---\n\n'
  fi
  printf '## What'\''s New\n\n%s\n' "$en_section"
fi

cat <<NOTES

---

## Install / 安装与升级

### Homebrew Cask (Recommended / 推荐，免弹窗)

\`\`\`bash
# First-time install / 首次安装
brew tap cassianpan/antigravity-usage-monitor https://github.com/cassianpan/antigravity-usage-monitor
brew install --cask antigravity-usage-monitor

# Upgrade / 从旧版本升级
brew update && brew upgrade --cask antigravity-usage-monitor
\`\`\`

### GitHub Releases (\`.dmg\` / \`.zip\`)

Download \`AntigravityUsageMonitor-$VERSION-macOS-arm64.dmg\` (or \`.zip\`) below and drag **Antigravity Usage Monitor.app** into \`/Applications\`.

Because this build is ad-hoc self-signed (not notarized by Apple), if macOS Gatekeeper blocks the first launch, choose **Open Anyway** in **System Settings › Privacy & Security**, or run:

\`\`\`bash
xattr -dr com.apple.quarantine "/Applications/Antigravity Usage Monitor.app"
\`\`\`

Requires macOS 15+ (Apple Silicon).
NOTES

if [ -n "$SHA" ]; then
  printf '\nZIP SHA-256: `%s`\n' "$SHA"
fi
