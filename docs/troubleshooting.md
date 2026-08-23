# 排障手册（全量踩坑记录）

> 本文档汇总了本套件在真实部署中踩过的所有坑。**部署前先通读**，遇到症状先查对应条目。

## 目录

1. [隧道相关](#1-隧道相关)
2. [守护进程相关](#2-守护进程相关)
3. [连接器相关](#3-连接器相关)
4. [权限与凭据相关](#4-权限与凭据相关)

---

## 1. 隧道相关

### 1.1 隧道永远起不来，keepalive 日志「凭据缺失」

```
✗ 凭据缺失（CONTROL_PLANE_TUNNEL_ID/API_KEY 为空），跳过拉起（下轮重试）
```

**原因**：`~/.dsh/.credentials.yaml` 里缺 CONTROL_PLANE_TUNNEL_ID 或 CONTROL_PLANE_API_KEY（或键名写错/带引号/带 \r）。
**解法**：补全两个键，去掉引号（脚本会剥引号但别依赖），确认文件无 BOM/CRLF。改完等 15s 自动拉起。

### 1.2 tunnel-client 控制面轮询全部超时 / ChatGPT 侧探测失败

**原因**：tunnel-client 没走代理。api.openai.com 直连不通，控制面 `/v1/tunnels/<id>/poll` 全部超时。
**解法**：
- keepalive/watchdog 的 launchd 环境已注入 `HTTPS_PROXY=http://127.0.0.1:7897`（install.sh 生成的 plist 自带）；
- 手动跑 tunnel-client 时必须自己带代理环境变量；
- Clash（或等价代理）必须开着。代理恢复后隧道自动连通，无需重启。

### 1.3 隧道 15 秒循环被杀重建（keepalive 日志刷「检测到 helm daemon 重启」）

**原因（早期版本的 bug）**：keepalive v2 早期版本的 state 文件只在健康分支写入；一旦进过重启分支，LAST_DAEMON_PID 永远不更新 → 每 15s 误判 daemon 重启 → 隧道循环被杀重建（实测 303 次/76 分钟）。此期间**本机探针全绿（假健康）**，ChatGPT 侧任务静默丢失。
**修复**：判定后无条件写 daemon pid 基线 + `-n` 守卫（state 缺失/首见 daemon 只建基线不触发重启）。**本仓库已是修复版**，若日志出现该症状检查是否用了旧版脚本。
**症状识别**：keepalive 日志反复出现「检测到 helm daemon 重启（pid → NNNN）」+ tunnel-client-manual.log 刷 poller stopped。

### 1.4 3458 显示 healthy 但 ChatGPT 连不上（假健康）

**原因**：3458 是 tunnel-client 自身健康端口，它只代表隧道进程活着；3457（daemon upstream）挂了时 3458 仍可能 live。v1 keepalive 只探 3458 导致假健康。
**修复**：v2 隧道健康 = **3458 自身 healthz 且 3457 upstream healthz** 双重判定（本仓库已含）。

### 1.5 daemon 重启后隧道还是旧的，ChatGPT 502

**原因**：daemon 重启（web 重启连带）后 MCP session 失效，旧隧道转发仍指向旧 session。
**修复**：keepalive v2 检测 daemon PID 变化 → 主动重启隧道重新初始化 MCP 会话（本仓库已含）。

### 1.6 两台机器抢同一个 tunnel_id

**原因**：同一 tunnel_id 同时只能有一个活跃 tunnel-client。
**解法**：多台机器**另建独立 tunnel**（docs/connector-creation.md），两台机器可同时在线。

---

## 2. 守护进程相关

### 2.1 web 被误杀（高负载下短暂不响应）

**原因**：watchdog v1 单次 3s 探针失败即 kill。
**修复**：v2 连续 3 次失败 + **3080/3457 双交叉确认**才动作；**仅 MCP 健康时绝不 kill**（保护活跃工具调用）。本仓库已是 v2。

### 2.2 web 重启后 helm daemon 成孤儿，新 web attach 卡死

**原因**：web 被 kill 后 daemon 进程残留（attach 模式 web 不管理 daemon 生命周期），新 web attach 到卡死 daemon。
**修复**：watchdog v2 重启前显式清理残留 daemon（SIGTERM→5s→SIGKILL）+ 删除陈旧 `~/.agent-chatgpt-helm/run/daemon.sock`。

### 2.3 双 watchdog / 双 keepalive 实例竞争

**原因**：mkdir 锁被绕过 / launchd 与手动实例并存。
**修复**：v2 单实例 = **PID 文件 + 存活校验 + 命令行校验**（ps 确认是脚本本身，防 PID 复用）。**不要手动重复启动**，用 launchctl kickstart。

### 2.4 改脚本后行为没变

bash 脚本常驻进程已把旧逻辑加载进内存。改脚本后必须重启组件：
```bash
launchctl kickstart -k gui/$(id -u)/com.dsh-connector.dsh-web-watchdog
launchctl kickstart -k gui/$(id -u)/com.dsh-connector.tunnel-client-keepalive
```

### 2.5 watchdog 拉起 web 失败（40s 未双就绪）

看 `~/.dsh/logs/dsh-web-watchdog-launch.log`（launch_web 的 stdout/stderr）。常见：
- HARNESS_DIR 不对（plist 里 DSH_HARNESS_DIR 覆盖了默认值）；
- node 路径不对（`$HARNESS_DIR/.tools/node22/bin/node` 不存在，依赖没装齐）；
- 3080 被别的进程占用（EADDRINUSE，之前手动开过第二个实例）。

### 2.6 daemon 日志里 tunnel 显示 managed（本应 disabled）

patch 没生效。确认 `~/.dsh/profiles/web/cordis.patch.yml` 含 `dsh-chatgpt-helm: tunnelEnabled: false`，**然后重启 web**（patch 在 web 启动时加载）。

---

## 3. 连接器相关

### 3.1 创建连接器得到「Installed 但 plugin_not_found」半成品

**原因**：创建时隧道不健康（tunnel-client 没跑 / 3458 不通），平台探测失败（424）。
**解法**：先修好隧道（verify.sh 全绿），然后 Plugin actions → **Uninstall** → 重新走创建流程。半成品无法直接修复。

### 3.2 连接器列表里有 app 但对话里不显示工具

- 确认点过 **Connect** 且弹窗 **Add to ChatGPT** 已确认（这一步才算启用）；
- 确认隧道健康（1.1~1.4）；
- 必要时 Uninstall 重建。

### 3.3 对话页 composer 锁住 / 无输入

ChatGPT 有 **Chat / Work 两个标签**，Work 标签额度耗尽会锁 composer。切回 Chat 标签。

### 3.4 自动化操作 ChatGPT 页面时找不到输入框

输入框是 ProseMirror contenteditable：
```
div[contenteditable=true][aria-label="Chat with ChatGPT"]
```

---

## 4. 权限与凭据相关

### 4.1 tunnel-client 用 env: 语法但值没生效

`--control-plane.api-key env:CONTROL_PLANE_API_KEY` 读的是**进程环境变量**，不是配置文件。keepalive/watchdog 脚本里已 `export`；**手动跑隧道前必须自己 export**。

### 4.2 MCP 401（unauthorized）

`~/.agent-chatgpt-helm/token` 与 daemon 当前 token 不一致（daemon 重启会重新生成？不会——token 存在文件里，daemon 每次启动读取该文件；若文件被删/重建则新旧不一致）。
**解法**：确认 token 文件存在且 0600；若重建过，重启隧道（keepalive 会自动做）让隧道带上新 token。

### 4.3 凭据/密钥泄露风险

- `~/.dsh/.credentials.yaml`、`~/.agent-chatgpt-helm/token` **禁止**进任何仓库（本仓库 .gitignore 已排除）；
- plist 模板不含任何真实值；
- 日志里 tunnel 相关输出默认会被 daemon 脱敏（REDACTED），但 keepalive 日志只记事件不记值。

### 4.4 代理端口不是 7897

Clash Verge 默认混合端口 7897。若代理软件端口不同：
- 手动改 plist 里的 EnvironmentVariables（HTTPS_PROXY 等）；
- keepalive 脚本里 `HTTPS_PROXY="http://127.0.0.1:7897"` 是硬编码 export，需要同步改。

### 4.5 权限问题

- 两个 LaunchAgent 都是用户域（gui/$(id -u)），无需 root；
- token 文件 0600，daemon 自动设置；
- serena 需要 TCC 权限（首次运行弹窗允许）。

---

## 附录：信息收集模板

报障时附上：

```bash
./scripts/verify.sh; echo "---"; 
tail -20 ~/.dsh/logs/dsh-web-watchdog.log
tail -20 ~/.dsh/logs/tunnel-client-keepalive.log
tail -20 ~/.dsh/logs/tunnel-client-manual.log
lsof -nP -iTCP:3080 -sTCP:LISTEN; lsof -nP -iTCP:3457 -sTCP:LISTEN; lsof -nP -iTCP:3458 -sTCP:LISTEN
```
