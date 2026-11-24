# Changelog

[中文更新日志](CHANGELOG.zh-CN.md)

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.8] - 2026-11-24

### Added

- **Grouped Active Processes with detached indicator & hover-to-terminate**: Merges `Antigravity.app` and its helpers into a single row with summed RSS memory, excludes macOS XPC services and background `agy-silent-sync-*` probes, labels orphaned CLI sessions (`PPID=1, TTY=??`) with an amber **Detached** badge, and adds a hover **Stop** button that terminates the full process subtree with `proc_bsdinfo` start-time PID-reuse protection.

### Changed

- **Smooth output speed sparkline**: Upgraded the 5-minute output speed sparkline from piecewise-linear segments to a Steffen monotone cubic Hermite spline (matching `claude-usage-monitor`).

### Fixed

- **Eliminated `agy` CLI orphan processes across Terminal sign-in & background sync**: Added two headless POSIX supervisors built into the main executable (`--cli-login-helper` and `--agy-sync-wrapper`). Terminal sign-in now watches `STDIN` with `poll(POLLERR|POLLHUP)` so closing the Terminal window immediately terminates `agy`, and auto-syncs, exits `agy`, and closes the opened Terminal window once sign-in completes. Background silent sync runs under a `kqueue` anonymous pipe-EOF watchdog (immune to parent `SIGKILL`), synchronous `applicationWillTerminate` / `SIGTERM` cleanup, startup orphan probe sweeping, and non-destructive `settings.json` merging.

## [0.1.7] - 2026-11-24

### Added

- **All-time cumulative API usage in Settings › Data**: Added a cumulative summary card showing all-time API-equivalent spend, total cache savings, total tokens (input / output / cache read), requests, sessions, cache hit rate, and start date.
- **Persistent full-week spend basis & daily run-rate projection**: Learns and persists the full-week spend/token basis once a week reaches ≥ 10% usage so projections stay available right after a weekly reset; falls back to current-cycle daily run-rate before a historical basis exists.

### Changed

- **Cleaner panel header & refined `Ultra` badge**: Removed the top-right update pill so update notices appear only as a subtle blue dot on bottom-left **Settings…** (clicking opens **Settings › General** with release notes expanded). Updated the `Ultra` badge from dark text on flat blue to white text on a blue-indigo gradient (`#3B82F6 → #6366F1`) matching the brand star.

## [0.1.6] - 2026-11-24

### Changed

- **Rendered Markdown release notes with collapsible view**: Replaced raw Markdown text in **Settings › General › Software updates** with a native `AttributedString` + `MarkdownNotesView` renderer (headings, bullet lists, bold, inline code) that automatically shows only the current language's changelog section and strips trailing install boilerplate. Notes stay collapsed by default and expand/collapse when clicking the update status line (or auto-expand when opened from the panel's update pill).
- **Cleaner update actions & faster auto-check**: Removed redundant `GitHub` and `brew` buttons from the update row (keeping an unobtrusive **Open in browser** link inside expanded notes) and shortened background auto-check cadence to every 4 hours.

## [0.1.5] - 2026-11-24

### Fixed

- **5-hour safe line settling buffer (first 30 minutes)**: Added the same 10% (`30 min`) settling phase as `claude-usage-monitor` at the start of each 5-hour window. Using 1%–5% right after a window opens no longer turns the bar red or triggers false over-pace warnings; hovering shows **Settling** until the window passes 30 minutes.

## [0.1.4] - 2026-11-24

### Added

- **In-app one-click self-updater**: Click **Update** in **Settings › General › Software updates** to download the latest `.zip` with a live 0%–100% progress bar, verify integrity against `SHA256SUMS.txt` using native `CryptoKit`, unpack with `ditto`, replace the `.app` in place, clear `com.apple.quarantine`, and relaunch automatically.
- **Built-in release notes & skip version**: Displays GitHub Release notes directly inside Settings, supports skipping the current version (automatically re-notifying on the next release), and keeps quick actions for GitHub and copying the `brew upgrade` command.
- **Quiet multi-touch update reminders**: Automatically checks GitHub `releases/latest` every 12 hours; shows an unobtrusive `↑ vX.Y.Z` pill in the panel header, a small accent badge on **Settings…**, and sends a single macOS notification per new version.

## [0.1.3] - 2026-11-24

### Added

- **Built-in GitHub update checker**: Added `UpdateChecker` and semantic version comparison to silently check GitHub Releases via public read-only APIs without uploading any user data.
- **Model-grouped quota limits with auto-collapse**: Grouped limits into **Gemini** and **Third-Party** sections, placing 5-hour and Weekly bars side by side per model family. Unused Third-Party groups collapse into a single clickable summary row and auto-expand as soon as usage occurs.

### Changed

- **Top-pinned `CADisplayLink` lockstep disclosure animation**: Refactored panel sizing (`TopPinnedRootLayout` + `DisclosureRevealContainer` + native `CADisplayLink`) so expanding/collapsing groups or toggling the 1-hour speed dot chart keeps the top edge locked beneath the menu bar while resizing the window, frosted glass, and content in lockstep with zero press-state text flicker.
- **Refined labels & typography**: Changed plan badges from all-caps `ULTRA` / `PRO` to title-case `Ultra` / `Pro`, and simplified `Third-Party (3P)` to `Third-Party`.

### Fixed

- **Consistent quota percentage & headroom math**: Derived `Remaining = 100 - Used` and `Headroom = max(0, Safe Line - Used)` from displayed integer percentages so the panel never shows `0% used / 99% remaining` or flags `0%` as over pace.
- **Inactive Third-Party buckets no longer shown as "Reset"**: Filtered Unix epoch placeholder timestamps (`1970-01-01T00:00:00Z`) so unused windows display **Not used yet**.
- **Eliminated distorted full-quota spend projections at low usage**: Raised the minimum weekly usage sample threshold for spend projection from `1%` to `10%`.
- **Fixed false "agy CLI sign-in required" alerts during silent sync**: Transient `authenticating` startup frames from `agy` no longer immediately trigger a sign-in warning; only sessions stuck without quota/email for over 5 seconds prompt re-login.

## [0.1.2] - 2026-11-23

### Fixed

- **Fixed `CHECKPOINT` compaction steps showing as "Unknown / Unpriced"**: System context-compaction `CHECKPOINT` entries in `transcript.jsonl` omit the `model` field. `TranscriptParser` and `TranscriptIndex` now inherit the conversation's last known model (and backfill leading model-less entries), preserving accurate token counts without false unpriced warnings.

## [0.1.1] - 2026-11-23

### Added

- **`.dmg` installer & Homebrew Cask distribution**: Added `make dmg`, automated `.dmg` + `.zip` + `SHA256SUMS.txt` builds in GitHub Actions, and `Casks/antigravity-usage-monitor.rb` (with automatic quarantine removal on install).
- **Updated bilingual READMEs**: Added the app icon, sanitized English & Chinese UI screenshots, self-signing / Gatekeeper guidance, credits to `kittors/claude-usage-monitor`, and architecture notes for forking to other AI agents.

### Fixed

- **Fixed launch crash (`SIGTRAP`) on Xcode 16 / Swift 6 release builds**: Switched `NotificationManager.requestPermissionIfNeeded()` to Swift Concurrency's native `async` `UNUserNotificationCenter.requestAuthorization(options:)` API to prevent `@MainActor` executor assertion crashes on background XPC callbacks.
- **Fixed deprecated Homebrew Cask syntax warning**: Updated `depends_on macos: ">= :sequoia"` to `depends_on macos: :sequoia`.

## [0.1.0] - 2026-11-23

### Added

- **Initial open-source release**: Native macOS 15+ (Apple Silicon) menu bar app built with pure Swift 6 and SwiftPM, with zero third-party dependencies.
- **Silent official quota sync**: Fetches official 5-hour and weekly quotas, reset timers, safe pace lines, and plan tier through the official `agy` CLI `statusLine` contract inside an ephemeral background PTY — zero packet capture, zero undocumented APIs, zero Keychain access.
- **Incremental local transcript analytics**: Parses `~/.gemini/antigravity/brain/**/transcript.jsonl` incrementally for input / cache-read / output tokens, cache hit rate, cache savings, per-model breakdown, 14-day trend bars, optional estimated output speed, and USD / CNY conversion.
- **Frosted glass floating panel & settings**: Customizable menu bar columns (defaulting to the tilted four-point star icon + 5H percentage), Detailed / Simple / Hidden section densities, English / Chinese UI, billing day reminders, and usage alerts.
