# Antigravity Usage Monitor

[![CI](https://github.com/panmingxuan/antigravity-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/panmingxuan/antigravity-usage-monitor/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/panmingxuan/antigravity-usage-monitor?style=flat-square&color=4F8CFF&label=release)](https://github.com/panmingxuan/antigravity-usage-monitor/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-2b2b2b?style=flat-square)](https://github.com/panmingxuan/antigravity-usage-monitor/releases/latest)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-4a4a4a?style=flat-square)](LICENSE)

[中文说明](README.zh-CN.md) · [Latest Release](https://github.com/panmingxuan/antigravity-usage-monitor/releases/latest)

A minimal, native macOS menu bar app (Swift 6 / macOS 15+) for monitoring **Google Antigravity** usage without packet capture, private endpoints, or keychain snooping.

## Highlights

- **Official 5-Hour & Weekly Limits (Zero Packet Capture, No Open Terminal Needed)**
  - Silently fetches official quota snapshots in the background via `agy --settings` without mutating your `settings.json` or keeping any Terminal window open.
  - Only requires a one-time Terminal sign-in if not authenticated yet; after signing in, you can close Terminal and the app syncs automatically.
  - Displays remaining/used percentages, countdown timers, and a **Safe Line** pace indicator (5-hour linear clock; weekly +1/7 per day — turns red when over pace).
  - Automatically drops a limit to 0% locally once `reset_time` elapses.
- **Exact Cache & Token Breakdown**
  - Incrementally parses local `~/.gemini/antigravity/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` files (covers both Antigravity Desktop and `agy` CLI sessions).
  - Tracks **Today / 5-Hour / Weekly** uncached input tokens, cache read tokens, output tokens, **cache hit rate**, per-model breakdown, and a **14-day daily trend**.
- **Active Context Window & Cost Estimates**
  - Displays the active CLI session's `context_window` utilization.
  - Estimates API-equivalent spend and cache savings using published list prices. Unknown/new models are transparently flagged rather than fabricated.
- **Safe One-Click Bridge Setup**
  - Automatically backs up `~/.gemini/antigravity-cli/settings.json` before configuring the bridge.
  - Uses `stack_with_default: true` when no custom `statusLine` exists, or chains your existing custom `statusLine` script without breaking it. Reversible with one click.
- **Native Menu Bar UX**
  - Menu-bar-only app (`LSUIElement`), showing only `5H` percentage by default with optional clickable columns (`WEEK` / `CACHE` / `TODAY` / `CTX`), translucent dark frosted-glass floating panel, English/Chinese language toggle, per-section **Detailed / Simple / Hidden** modes, and Login Item support.

## Requirements

- macOS 15+
- Swift 6 toolchain (Xcode 16+ or Command Line Tools)

## Build & Self-Sign

```bash
# Run unit tests (UsageCore)
make test

# Build and ad-hoc self-sign build/Antigravity Usage Monitor.app
make app

# Or sign with your own local code-signing certificate in Keychain
CODESIGN_IDENTITY="My Local Dev Cert" make app
```

Then copy `build/Antigravity Usage Monitor.app` to `/Applications` (or run `make run`).

## Privacy

- Zero network requests.
- Zero keychain reads or writes.
- All transcript parsing and statusLine snapshots stay strictly on your Mac.

## License

[MIT](LICENSE)
