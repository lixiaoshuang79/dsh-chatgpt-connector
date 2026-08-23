# Changelog

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 语义化版本（[SemVer](https://semver.org/lang/zh-CN/)）。

## [0.1.1] - 2026-08-24

### Added

- watchdog/keepalive **liveness/stall detection（假死检测）**：web UI 连续不健康但 MCP 健康时，查询 supervisor_health 的 activeSessions —— 有活跃会话则保护不重启（长任务进行中），无活跃会话且翻倍阈值（6 次 ≈ 60s）仍不健康才判定假死并重启
- **故障诊断快照**：自愈动作（重启 web / 重建隧道）前把进程/端口/日志 tail 落盘到 `~/.dsh/logs/diagnostics/<时间戳>/`（保留最近 10 份），便于事后定位根因
- keepalive **重建限速防抖**：60s 内最多重建 3 次，防止 daemon 短暂缺席时每 15s 疯狂重建隧道
- 快照内容**凭据脱敏**：`sk-` / `tunnel_` / `asdk_app_` 等凭据形态值自动打码

### Fixed

- keepalive daemon-down 抖动：daemon 探测为空（web 重启窗口内短暂缺席）时不再误判「daemon 重启」触发隧道重建（实测曾每 15s 杀隧道重建 60+ 次）
- 测试套件端口冲突：固定端口 + 预清理杀任意监听者 → 改为 **python bind(0) 动态分配空闲端口**（不再 kill 未知进程）
- 测试隔离：快照/防抖状态文件指向测试临时目录，不写真实 `~/.dsh/logs`

## [0.1.0] - 2026-08-23

### Added

- ChatGPT → DSH（DeepSeek Harness）连接部署套件：
  - `scripts/tunnel-client-keepalive.sh`：OpenAI Secure MCP Tunnel 隧道守护（15s 探针 3458+3457，daemon PID 变化自动重建隧道，单实例 PID 锁）
  - `scripts/dsh-web-watchdog.sh`：DSH web 守护（10s 探针 3080+3457，连续 3 次双失败才受控重启，残留 daemon/socket 清理）
  - `scripts/install.sh`：一键部署（依赖检查、LaunchAgent 安装、cordis.patch.yml 合并、凭据校验）
  - `scripts/verify.sh`：部署后 4 层健康验证（3080/3457/3458/supervisor_health）
  - `launchd/*.plist.tpl`：LaunchAgent 模板（占位符化，install.sh 生成实际 plist）
  - `patches/helm-tunnel.patch.yml`：dsh-chatgpt-helm 隧道所有权补丁（daemon 不自管隧道，keepalive 独占）
  - `docs/`：架构、连接器创建流程、验证清单、排障手册
  - `tests/`：37 断言故障注入测试套件（watchdog 决策/keepalive 守护/残留清理/高负载）

### Fixed

- keepalive 死循环：state 文件只在健康分支写入导致 daemon PID 基线永不更新 → 隧道 15s 循环被杀重建（判定后无条件写基线 + `-n` 守卫）
- watchdog 误杀：单次 3s 探针失败即 kill → 连续 3 次 + 3080/3457 双交叉确认；MCP 健康时绝不 kill
- 3458 假健康：隧道健康改为 3458 且 3457 双重判定
- daemon 孤儿：web 重启前显式清理残留 daemon + 删除陈旧 daemon.sock
- 双隧道竞争：daemon 自管隧道与 keepalive 互杀 → patch `tunnelEnabled: false`，keepalive 独占
- 测试入口 `tests/run-tests.sh` 的 `cd` 路径 bug（`cd tests/tests` 报错）
- 测试文件硬编码本机绝对路径 → 改为从脚本位置自适应推导
