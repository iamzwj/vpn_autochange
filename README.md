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
`https://chatgpt.com/` 连通性为准，单次超时 2800 ms。
所有全量测试结果追加保存到
`~/Library/Application Support/vpn_autochange/tests.jsonl`，重启后继续累计。
前十按历史成功率降序、样本数降序、最近延迟升序排列；没有成功记录或
已从订阅移除的节点不入池。心跳不计入排名，避免当前节点样本偏差。
界面显示成功率、成功/总次数及最近延迟，双击节点可切换。
每 3 秒检测当前节点，首次失败即复测前十池并切换到本轮延迟最低的可用节点。
故障恢复期间心跳串行等待，避免并发切换。池内全部失败则保持告警，等待后续全量检测。
