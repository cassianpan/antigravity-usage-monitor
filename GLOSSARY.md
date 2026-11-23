# 领域术语表（GLOSSARY）

| 术语 | 定义 | 备注 |
| --- | --- | --- |
| 5 小时限额（5-hour limit） | Antigravity 按 5 小时滚动窗口计算的模型配额上限，由官方 `statusLine` 的 `quota` 字段推送剩余比例与重置时间 | 与官方 `/usage` 面板口径一致 |
| 周限额（Weekly limit） | Antigravity 按 7 天周期计算的模型配额上限，由官方 `statusLine` 的 `quota` 字段推送剩余比例与重置时间 | 对应如 `gemini-weekly` 等配额桶 |
| 安全配速线（Safe Line） | 进度条上随当前时间推进的基准消耗线（5h 窗口按分钟线性推进，周窗口按天 1/7 推进），实际使用率超过基准线时预警变红 | 参考 `kittors/claude-usage-monitor` |
| 缓存命中率（Cache Hit Rate） | `cache_read_tokens / (input_tokens + cache_read_tokens)`（或按实际字段口径精确定义），用于衡量上下文缓存节省比例 | 来源于本地 `transcript.jsonl` |
| statusLine 桥接（StatusLine Bridge） | 配置在 `~/.gemini/antigravity-cli/settings.json` 中的轻量脚本，接收 `agy` CLI 通过 `stdin` 推送的 JSON 状态并原子写入本地快照文件供 App 读取 | 不抓包、不调用未公开接口 |
| 本地对话日志（Transcript） | `~/.gemini/antigravity/brain/<conversation-id>/.system_generated/logs/transcript.jsonl`，记录每步模型调用的时间、模型名与 Token 消耗 | 桌面端与 CLI 会话均落盘于此 |
