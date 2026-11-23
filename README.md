# Antigravity Usage Monitor

[中文说明](README.zh-CN.md)

A minimal, native macOS menu bar app (Swift 6 / macOS 15+) for monitoring **Google Antigravity** usage without packet capture, private endpoints, or keychain snooping.

## Highlights

- **Official 5-Hour & Weekly Limits (Zero Packet Capture)**
  - Uses Antigravity CLI's official `statusLine` JSON hook via a lightweight local bridge script.
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
