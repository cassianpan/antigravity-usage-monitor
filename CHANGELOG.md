# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.4] - 2026-11-24

### Added

- **In-app one-click self-updater / 应用内一键自更新**：在「设置 › 通用 › 软件更新」点击「立即更新」即可在应用内完成带实时进度条（0%–100%）的 `.zip` 下载、系统原生 `CryptoKit` SHA-256 核对（对照 `SHA256SUMS.txt`）、`ditto` 解压，以及退出后自动原地替换 `.app`、清除 `com.apple.quarantine` 隔离属性并重新拉起新版本。
- **内置更新日志与忽略此版本**：设置页直接展示当前最新版本的 Release Notes，支持「忽略此版本」（仅跳过当前版本提醒，下一个新版本自动恢复提醒），并保留「GitHub」和「复制 brew 升级命令」快捷入口。
- **多触点低打扰提醒**：每 12 小时静默检查 GitHub `releases/latest`；发现新版本时，主面板右上角显示 `↑ vX.Y.Z` 胶囊、底栏「设置…」亮起小蓝点角标，并推送一次 macOS 系统通知。

## [0.1.3] - 2026-11-24

### Added

- **内置 GitHub 新版本检查**：新增 `UpdateChecker` 与语义版本号比较，启动及定时静默检查 GitHub Releases 最新版本（纯只读公开 API，不上传任何隐私数据）。
- **用量限额按模型分组与自动折叠**：将配额按 `Gemini` 与 `第三方模型` 分组展示，每组下紧挨显示「5 小时」与「本周」进度条；当第三方模型本周期尚未使用时自动折叠为一行紧凑摘要（可点击展开/收起），一旦产生用量自动展开。

### Changed

- **顶部锁死 + `CADisplayLink` 锁步展开动效**：重构浮层面板尺寸管理（`TopPinnedRootLayout` + `DisclosureRevealContainer` + 原生 `CADisplayLink`），展开/收起第三方模型或切换 1 小时输出速度热点图时，面板顶部严格固定在菜单栏下方，窗口、毛玻璃与内容同帧向下平滑伸展/收回，并消除按钮按下时的文字闪动。
- **订阅标签排版优化**：顶部订阅徽章由全大写 `ULTRA` / `PRO` 调整为首字母大写 `Ultra` / `Pro`；将「第三方模型 (3P)」精简为「第三方模型」。

### Fixed

- **修复额度百分比与安全余量算术不一致**：统一按展示整数派生 `剩余 = 100 - 已用` 与 `安全余量 = max(0, 安全线 - 已用)`，避免同时出现「已用 0% / 剩余 99%」或「显示 0% 却标红超安全线」。
- **修复未激活第三方模型桶误判为「已重置」**：过滤官方占位时间 `1970-01-01T00:00:00Z`，未用过的周期桶正确展示「本周期未使用」。
- **修复小样本下满额预计花费虚高**：将周额度满额推算的最低样本门槛从 `1%` 提高至 `10%`，避免周期刚开始时外推出失真的数千美元预估值。
- **修复后台静默同步误报「agy CLI 的登录已失效」**：`agy` 启动瞬间短暂经过 `authenticating` 状态不再立刻判定为登录失效，仅当持续超过 5 秒仍无配额/账号信息时才提示重新登录。

## [0.1.2] - 2026-11-23

### Fixed

- **修复上下文压缩步 `CHECKPOINT` 触发「含未定价模型 / Unknown」**：`transcript.jsonl` 中系统自动压缩上下文生成的 `CHECKPOINT` 记录不含 `model` 字段；`TranscriptParser` 与增量游标 `TranscriptIndex` 现会自动继承当前会话最近使用的模型名（并对文件开头缺失模型名的记录做向前回填），既保留完整 token 统计又不再误报 `Unknown`。

## [0.1.1] - 2026-11-23

### Added

- **新增 `.dmg` 镜像打包与 Homebrew Cask 分发**：支持 `make dmg` 与 GitHub Actions 自动产出 `.dmg`、`.zip` 与 `SHA256SUMS.txt`；新增 `Casks/antigravity-usage-monitor.rb`（安装后自动清除 `com.apple.quarantine` 实现免弹窗启动）。
- **完善中英文 README**：新增应用图标、脱敏中英文高清界面截图、自签与 Gatekeeper 放行指南、原项目 `claude-usage-monitor` 致谢，以及 Fork 适配其他 AI Agent 的架构说明。

### Fixed

- **修复云端 Xcode 16 / Swift 6 打包版启动闪退（`SIGTRAP`）**：`NotificationManager.requestPermissionIfNeeded()` 改用 Swift Concurrency 原生 `async` 接口 `UNUserNotificationCenter.current().requestAuthorization(options:)`，修复 ObjC completion handler 在后台 XPC 线程回调触发 `@MainActor` 隔离断言崩溃的问题。
- **修复 Homebrew Cask 废弃语法警告**：将 `depends_on macos: ">= :sequoia"` 更新为 `depends_on macos: :sequoia`。

## [0.1.0] - 2026-11-23

### Added

- **首个开源版本发布**：纯 Swift 6 + SwiftPM（macOS 15+ Apple Silicon，零第三方依赖）原生菜单栏应用。
- **官方配额静默同步**：通过官方 `agy` CLI `statusLine` 契约与后台 PTY 临时会话静默获取 5 小时与每周额度、重置时间、安全线与订阅方案——零抓包、零未公开接口、零 Keychain 访问。
- **本地对话增量统计**：增量解析 `~/.gemini/antigravity/brain/**/transcript.jsonl`，计算新增输入 / 缓存命中 / 输出 Token、缓存命中率与节省金额、按模型占比、14 天趋势柱图、可选估算输出速度，以及 USD / CNY 汇率换算。
- **原生毛玻璃浮层与设置窗口**：支持菜单栏自定义列（默认仅显示倾斜四角星图标与 5H 百分比）、面板区块「详细 / 简洁 / 隐藏」切换、中英文切换、账单日提醒与额度预警通知。
