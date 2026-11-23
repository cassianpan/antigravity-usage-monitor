# AGENTS.md

## 任务平台
- 平台：github（仓库 `panmingxuan/antigravity-usage-monitor`）
- 计划位置：issue
- 创建 issue 前：不需要

## 项目约定
- 纯 Swift 6 + SwiftPM（macOS 15+），零第三方依赖。
- 严格区分官方配额数据（来自 `agy` CLI 官方 `statusLine` 桥接快照）与本地统计数据（来自 `~/.gemini/antigravity/brain/**/transcript.jsonl`），绝不做抓包或调用未公开接口。
- 提交记录与 PR 不添加 AI 署名行。
