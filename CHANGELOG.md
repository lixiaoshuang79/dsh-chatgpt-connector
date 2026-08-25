# Changelog

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/) 语义化版本（[SemVer](https://semver.org/lang/zh-CN/)）。

## [0.3.0] - 2026-08-25

### Added

- **模型门禁（mcp-proxy）**：`sessions_create`/`sessions_prompt`（含 `mode=steer`）声明式校验 ChatGPT 模型——隧道协议无 model 字段（实测确认），由 ChatGPT 侧系统指令在消息第一行声明（模板见 [docs/model-gate.md](docs/model-gate.md)）：
  - `gpt-5-6-thinking` 放行；`5.5-mini` 拒绝（`model_rejected` 附 received）；无声明拒绝（`model_declaration_required`）
  - 被拒 = MCP `isError` + `[模型门禁拒绝]` 结构化 JSON 文案（ChatGPT 端工具错误可见），含模型声明格式与重发指引
  - `mcp-proxy/lib/model-gate.mjs`（零依赖，与 dsh-helm hub 侧同源实现），`tests/test-proxy.mjs` 新增门禁用例（7 用例全过）
- **Goal 守卫（patches/goal-guard.mjs + docs/goal-guard.md）**：ChatGPT 指令禁止在 DSH 开启 goal（消息以 `relayedBy:"dsh-chatgpt-helm"` 注入保持 GUI 可见 + goal 权威校验排除该标记），幂等补丁、自动备份，与 dsh-helm 同源

### Changed / Fixed

- 既有测试用例的注入消息补模型声明前缀（适配门禁契约）

## [0.2.0] - 2026-08-24


### Added

- **mcp-proxy（升级能力层）**：tunnel 与 helm daemon 之间的本地 MCP 代理（`mcp-proxy/`，Node 原生零依赖），为单机链路提供三项升级能力：
  - **内容瘦身**：`sessions_get` 默认返回结构化摘要（~KB：current_goal 行动性排序附来源 seq / recent_evidence / history_ref / 凭据清洗 / 60s 缓存，写操作后失效）；完整历史显式 `include_messages=true` 才取
  - **插队机制**：`sessions_prompt mode=steer` 经 DSH 宿主 API（3080）立即注入运行中回合，结构化返回 `steered/queued/rejected/unavailable`（宿主不可达不崩链路，queue 照常）
  - **响应守卫**：所有 `tools/call` 响应超 50KB 统一截断（保持合法 JSON + `truncated` 元数据）
  - 实现思路与 dsh-helm 同源（@ 3c3219d），本仓库自包含、单机零依赖
- launchd 模板 `com.dsh-connector.mcp-proxy` + install/verify/uninstall 接线；tunnel 默认走代理（`HELM_MCP_PORT=3461`，keepalive 探针拆分 `HELM_UPSTREAM_PORT=3457` 保持真实 daemon 活性检测）
- `tests/test-proxy.mjs`（node:test 全链路 6 用例：摘要瘦身/守卫截断/steer 插队/降级/透传与缓存失效/daemon 容错），纳入 `tests/run-tests.sh`

### Fixed

- keepalive 健康探针端口与 tunnel server-url 端口解耦（代理介入后探针仍探真实 daemon）

## [0.1.1] - 2026-08-24

### Added

- watchdog/keepalive datapath liveness/stall detection（数据链活性检测）：
  - 不再把 MCP `/healthz`（仅 daemon 进程活性）当作 runtime 活性——UI 连续失败 ≥3 且 MCP 健康时，通过 MCP initialize + 只读 `sessions_list`（5s timeout）探测 daemon→adapter→DSH session 完整数据链
  - `sessions_list` 成功：判定 session datapath 活，清 stall，不重启（高负载/长任务保护）
  - `sessions_list` 连续失败：进入 datapath stall
  - activeSessions=0 时连续 2 轮 stall → snapshot → restart（web 假死自愈）
  - activeSessions>0 时 `STALL_SINCE` 保留，`WATCH_ACTIVE_STALL_GRACE_SEC=300` 默认保护；超过 grace 且仍 stall → snapshot → restart（不会永久保护卡死 session）
- 故障诊断快照：自愈动作（重启 web / 重建隧道）前把进程/端口/日志 tail 落盘到 `~/.dsh/logs/diagnostics/<时间戳>/`（保留最近 10 份）
- keepalive 重建限速防抖：60s 内最多重建 3 次，防止 daemon 短暂缺席时每 15s 疯狂重建隧道
- 快照内容凭据脱敏：`sk-` / `tunnel_` / `asdk_app_` 等凭据形态值自动打码
- `tests/test-stall-detection.sh`：datapath stall 四场景独立测试（UI fail+datapath ok / fail+active0 / fail+active>0 within grace / fail+active>0 beyond grace）

### Fixed

- bash 3.2 `set -u` + 多字节字符 + `$var` 相邻展开 bug：`（pid=$old_pid）` 中文括号紧贴变量导致 `old_pid: unbound variable` 误报（实际运行环境手动重跑 watchdog 即触发）→ 中文标点与变量分离（`(pid=${old_pid})`）。**全量排查修复其余 9 处同类问题**（install.sh 7 处、watchdog 1 处、keepalive 1 处），CI 增加 CJK 紧贴 `$var` 正则守卫防回归
- watchdog 重启熔断：10 分钟内 ≥3 次重启进入 5 分钟冷却，避免持续故障时无限重启风暴
- watchdog 防误杀：restart 前校验 3080 占用进程确为 dsh（is_dsh），端口被无关进程占用时不 kill
- watchdog 兜底拉起去重：60s 窗口内不重复拉起（防冷启动慢时 spawn 第二个实例）
- watchdog/keepalive 拉起前二进制存在性检查（node/tunnel-client 缺失时明确报错而非静默失败）
- watchdog 凭据缺失告警：凭据文件缺失/为空时写日志告警（daemon 不再以空凭据静默启动）
- keepalive 锁冲突空转：第二实例 sleep 60s 再退出（防 launchd KeepAlive 空转循环）
- keepalive kill_tunnel 循环杀全部匹配实例（防旧僵尸 + 新实例并存只杀一个）
- uninstall 缩进补丁段识别：grep 允许前导空白（与 install 一致），校验按 `- id:` 行计数
- verify.sh 跳过项不再重复计入失败（SKIP/FAIL 分开统计）
- `local` 声明移出 `if` 复合命令块（bash 3.2 作用域边界问题）
- keepalive daemon-down 抖动：daemon 探测为空时不再误判「daemon 重启」触发隧道重建
- 测试套件端口冲突：固定端口 + 预清理杀任意监听者 → python bind(0) 动态分配空闲端口（不再 kill 未知进程）
- 测试隔离：快照/防抖状态文件指向测试临时目录，不写真实 `~/.dsh/logs`；fake daemon 命令行加 `-test` 标记，不再匹配生产 pgrep 模式（生产机跑测试不误伤实际运行的隧道）

## [0.1.0] - 2026-08-23

### Added

- ChatGPT → DSH（DeepSeek Harness）连接部署套件：
  - `scripts/tunnel-client-keepalive.sh`：OpenAI Secure MCP Tunnel 隧道守护（15s 探针 3458+3457，daemon PID 变化自动重建隧道，单实例 PID 锁）
  - `scripts/dsh-web-watchdog.sh`：DSH web 守护（10s 探针 3080+3457，连续 3 次双失败才受控重启，残留 daemon/socket 清理）
  - `scripts/install.sh`：部署（依赖检查、LaunchAgent 安装、cordis.patch.yml 合并、凭据校验）
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
