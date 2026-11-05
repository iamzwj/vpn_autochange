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
前十按历史成功率降序、样本数降序、最近延迟升序排列；没有成功记录或
已从订阅移除的节点不入池。心跳不计入排名，避免当前节点样本偏差。
界面显示成功率、成功/总次数及最近延迟，双击节点可切换。
每 3 秒检测当前节点，首次失败即复测前十池并切换到本轮延迟最低的可用节点。
故障恢复期间心跳串行等待，避免并发切换。池内全部失败则保持告警，等待后续全量检测。

旧版首页探测历史 tests.jsonl 保留，新标准单独累计。切换后仅关闭经过目标代理组、
仍走其他节点的 ChatGPT/OpenAI 连接，客户端可能显示一次重连以使用新节点。
