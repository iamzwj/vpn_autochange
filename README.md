# 节点切换

节点切换 is a small macOS companion for Clash Verge Rev / Mihomo.

It reads the local Clash Verge controller configuration and secret from:

`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml`

It prefers Clash Verge's private Unix Socket, so no external TCP controller
needs to be enabled. It automatically detects common main groups such as
`节点选择`, `Proxies`, `自动选择`, and `GLOBAL`.

The app does not include, create, or sell proxy nodes. Clash Verge must be
running and a valid subscription must already be active.

## 长期稳定池

应用启动即全量检测实际代理节点，每批最多并发测试 45 个，每轮结束 5 秒后再检测。以
两个地址的网络可达性为标准：`https://chatgpt.com/backend-api/models` 与
`https://ws.chatgpt.com/`，单项超时 2800 ms，每批 45 个节点。
节点池百分比是双目标网络探测历史成功率，不代表登录对话成功率。
已实测本机核心忽略 delay API 的 expected 参数，因此不依赖它判断 HTTP 状态。
当前使用路径另通过本地 mixed-port 发出真实 HTTPS 请求，严格要求 API 返回 401、
WebSocket 主机返回 404；403 等响应视为失败。两者仍不是带凭据的对话或 WebSocket 升级验证。
所有全量测试结果追加保存到
`~/Library/Application Support/vpn_autochange/service-tests-v2.jsonl`，重启后继续累计。
实测池按下方列出的固定分级使用。界面展示固定 Codex 实测成功率、次数和最近网络探测延迟，
双击节点可切换。每 3 秒检测当前节点，连续失败 2 次后检测实测池并切换。
故障恢复期间心跳串行等待，避免并发切换。池内全部失败则保持告警，等待后续检测。

旧版首页探测历史 tests.jsonl 保留，新标准单独累计。切换后仅关闭经过目标代理组、
仍走其他节点的 ChatGPT/OpenAI 连接，客户端可能显示一次重连以使用新节点。

## Codex 实测节点池

2026-11-09 使用本机已登录的 Codex CLI 和 gpt-6.1-sol，通过 Mihomo 代理轮测
300 秒，10 个节点共 25 次短回复请求全部完成。原始结果见
codex-node-pool-results.json。样本为每节点 2–3 次，不代表长任务稳定率。
应用列表中的成功率和成功次数来自这次固定实测，最近延迟继续来自网络探测。

自动选择优先检测日本标准 IEPL 专线 5、2、3，其次美国标准 IEPL 专线
2、6、8，最后荷兰 1、2、德国 1、匈牙利 1。每级按当前网络探测延迟选择可达节点。
仅使用当前订阅仍包含的实测节点。当前心跳仍为 HTTP 校验，
连续失败 2 次才切换；日常运行不会自动消耗 Codex 额度。
