# Antigravity Usage Monitor

[![CI](https://github.com/panmingxuan/antigravity-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/panmingxuan/antigravity-usage-monitor/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/panmingxuan/antigravity-usage-monitor?style=flat-square&color=4F8CFF&label=release)](https://github.com/panmingxuan/antigravity-usage-monitor/releases/latest)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-2b2b2b?style=flat-square)](https://github.com/panmingxuan/antigravity-usage-monitor/releases/latest)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=flat-square)](Package.swift)
[![License: MIT](https://img.shields.io/badge/license-MIT-4a4a4a?style=flat-square)](LICENSE)

[English](README.md) · [下载最新版](https://github.com/panmingxuan/antigravity-usage-monitor/releases/latest)

一个原生、轻量的 macOS 菜单栏应用（Swift 6 / macOS 15+），用于展示 **Google Antigravity** 的官方 5 小时/周限额、缓存命中率、输入/输出 Token 与估算花费。**不做抓包、不调用未公开接口、不读取钥匙串。**

## 核心特性

- **官方 5 小时与周限额（零抓包、免值守终端）**
  - 通过官方 `agy --settings` 临时会话参数在后台静默拉取官方 `statusLine` 配额快照，不修改用户的 `settings.json`，也不需要一直开着终端窗口。
  - 仅在首次登录或登录过期时打开一次终端完成 `agy` 登录，登录完即可关闭终端，后续由 App 自动后台刷新。
  - 展示剩余/已用百分比、重置倒计时与**安全配速线（Safe Line）**（5 小时按时间线性推进，周限额按天 1/7 推进，超速变红提醒）。
  - 到达 `reset_time` 后本地自动归零；长期未运行 CLI 时明确标注上次同步时间，绝不用本地估算冒充官方百分比。
- **精确缓存与输入/输出 Token 拆解**
  - 增量解析本地 `~/.gemini/antigravity/brain/<会话ID>/.system_generated/logs/transcript.jsonl`（同时覆盖 Antigravity 桌面端与 `agy` CLI 对话）。
  - 统计 **今日 / 近 5 小时 / 本周** 的新增输入 Token、缓存命中 Token、输出 Token、**缓存命中率**、**按模型拆分** 与 **14 天每日趋势图**。
- **活跃会话上下文窗口与费用估算**
  - 实时展示当前活跃 `agy` 会话的 Context Window 占用比例。
  - 按公开模型单价估算 API 等价花费与缓存节省金额；遇到内置价格表未收录的新模型时，照常计入 Token 并明确标注「含未定价模型」，绝不编造单价。
- **安全的一键接入与还原**
  - 接入前自动备份 `~/.gemini/antigravity-cli/settings.json`。
  - 未配置过自定义 `statusLine` 时自动启用 `stack_with_default: true` 保留官方默认状态栏；检测到已有自定义脚本时自动链式包装，不破坏原有配置，随时可一键还原。
- **原生菜单栏交互**
  - 纯菜单栏常驻（无 Dock 图标），默认仅显示 `5H` 百分比，可在设置页按需点亮叠加 `WEEK` / `CACHE` / `TODAY` / `CTX`，采用原生暗色毛玻璃浮层面板与中/英双语切换，支持各区块 **详细 / 简洁 / 隐藏** 与开机自启。

## 环境要求

- macOS 15 及以上
- Swift 6 工具链（Xcode 16+ 或 Command Line Tools）

## 本地编译与自签

```bash
# 运行核心数据层单元测试
make test

# 编译并默认 ad-hoc 自签生成 build/Antigravity Usage Monitor.app
make app

# 也可指定本机钥匙串中的自建代码签名证书
CODESIGN_IDENTITY="你的本地证书名" make app
```

构建完成后，可将 `build/Antigravity Usage Monitor.app` 拖入 `/Applications`，或直接运行 `make run`。

## 隐私说明

- 零网络请求。
- 零钥匙串读写。
- 所有对话日志解析与状态快照均严格保留在本机。

## 开源协议

[MIT](LICENSE)
