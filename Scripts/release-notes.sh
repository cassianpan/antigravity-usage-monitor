#!/usr/bin/env bash
# Generate GitHub Release notes from CHANGELOG.md + install instructions.
# Usage: Scripts/release-notes.sh <version> [zip_sha256]
set -euo pipefail

VERSION="${1:?usage: Scripts/release-notes.sh <version> [zip_sha256]}"
VERSION="${VERSION#v}"
SHA="${2:-}"
cd "$(dirname "$0")/.."

section="$(awk -v v="$VERSION" '
  /^## / { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
  found { print }
' CHANGELOG.md)"

if [ -z "$section" ]; then
  echo "CHANGELOG.md has no section for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$section" | sed -e '/./,$!d'

cat <<NOTES

---

## Install / Upgrade

### Homebrew Cask (Recommended — No Gatekeeper Prompt)

\`\`\`bash
# First-time install
brew tap cassianpan/antigravity-usage-monitor https://github.com/cassianpan/antigravity-usage-monitor
brew install --cask antigravity-usage-monitor

# Upgrade from an earlier version
brew update && brew upgrade --cask antigravity-usage-monitor
\`\`\`

### GitHub Releases (\`.dmg\` or \`.zip\`)

1. Download \`AntigravityUsageMonitor-$VERSION-macOS-arm64.dmg\` (or \`.zip\`) below.
2. Drag **Antigravity Usage Monitor.app** into \`/Applications\` and open it.
3. Because this build is ad-hoc self-signed (not notarized by Apple), if macOS Gatekeeper blocks the first launch, choose **Open Anyway** in **System Settings › Privacy & Security**, or run:

   \`\`\`bash
   xattr -dr com.apple.quarantine "/Applications/Antigravity Usage Monitor.app"
   \`\`\`

Requires macOS 15+ (Apple Silicon).
NOTES

if [ -n "$SHA" ]; then
  printf '\nZIP SHA-256: `%s`\n' "$SHA"
fi
