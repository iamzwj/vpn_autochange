# 节点切换

节点切换 is a small macOS companion for Clash Verge Rev / Mihomo.

It reads the local Clash Verge controller configuration and secret from:

`~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml`

It prefers Clash Verge's private Unix Socket, so no external TCP controller
needs to be enabled. It automatically detects common main groups such as
`节点选择`, `Proxies`, `自动选择`, and `GLOBAL`.

The app uses one merged Codex stability pool across subscriptions:

- `香港-IEPL 02`
- `澳门-IEPL`
- `高级 专线 日本 10`
- `高级 专线 美国 15`

If every primary node fails, it automatically falls back to a secondary pool
containing the next-best measured nodes from both subscriptions. Remote proxy
providers are refreshed only after both pools fail.

It automatically uses the stable names present in the current subscription, so
no manual subscription mode is required. The app monitors the active main group
every three seconds with a two-second ChatGPT heartbeat timeout:

1. Measure the currently selected node.
2. After the first failed health check, test matching nodes and switch to the
   lowest-latency healthy candidate.
3. If every matching candidate fails, refresh remote proxy providers.
4. Notify the user when the connection recovers and keep a reconnect history.

The app does not include, create, or sell proxy nodes. Clash Verge must be
running and a valid subscription must already be active.
