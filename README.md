# dsh-chatgpt-connector

单机 ChatGPT ↔ 本地 DeepSeek Harness (DSH) 连接套件：在 macOS 上用 OpenAI Secure MCP Tunnel 让 ChatGPT 调用本机 DSH 的 MCP 工具（读代码、管理会话、执行任务），不需要多节点控制平面。

```
ChatGPT ── Secure MCP Tunnel ──> tunnel-client (3458) ──> mcp-proxy (3461) ──> helm daemon (3457) ──> DSH web (3080)
```

所有服务只监听 `127.0.0.1`；MCP 调用带 Bearer token；凭据存 `~/.dsh/.credentials.yaml`（0600），不入库。安全模型见 [SECURITY.md](SECURITY.md)。

## 升级能力（mcp-proxy，单机也有）

tunnel 与 daemon 之间的本地 MCP 代理（`mcp-proxy/`，Node 原生零依赖），把 dsh-helm 控制平面的升级能力带到单机链路（逻辑同源 vendored）：

- **内容瘦身**：`sessions_get` 默认返回结构化摘要（~KB：current_goal/recent_evidence/history_ref/凭据清洗/60s 缓存），大会话不再整体抛给 ChatGPT；完整历史显式 `include_messages=true` 才取
- **插队机制**：`sessions_prompt` 带 `mode=steer` 立即注入运行中回合（`steered/queued/rejected/unavailable` 结构化返回），不再干等长任务
- **响应守卫**：所有 `tools/call` 响应超 50KB 统一截断（合法 JSON + `truncated` 元数据），ChatGPT 侧永不收到超大响应

`install.sh` 自动安装代理服务并让 tunnel 走代理（3461）；想临时绕过：keepalive 环境变量 `HELM_MCP_PORT` 改回 `3457`。测试：`tests/test-proxy.mjs`（node:test 全链路）。

## 适用场景

- 想在一台电脑上用 ChatGPT 控制本机 DSH 的用户
- 需要多机器、多节点控制面的场景请用 [dsh-helm](https://github.com/lixiaoshuang79/dsh-helm)（multi-node control plane），本仓库是 single-machine bridge，两者适用场景不同

## 前置条件

| 依赖 | 说明 |
|---|---|
| macOS 14+，Node.js 22+ | 需已 clone deepseek-harness 并装好依赖 |
| dsh CLI | 在 PATH |
| tunnel-client | OpenAI 官方二进制（v0.0.12+），放 `~/.local/bin/tunnel-client` |
| serena | `uv tool install -p 3.13 serena-agent && serena init` |
| 代理 | 监听 `127.0.0.1:7897`（海外 API 需走代理） |
| OpenAI Platform 隧道 | 本机专属 tunnel + API key，见 [docs/connector-creation.md](docs/connector-creation.md) |

全新 Mac 首次 clone 会提示安装 Xcode Command Line Tools，同意即可。

## 快速开始

```bash
# 1. 克隆
git clone https://github.com/lixiaoshuang79/dsh-chatgpt-connector.git
cd dsh-chatgpt-connector

# 2. 配置凭据（先按 docs/connector-creation.md 建好隧道）
#    编辑 ~/.dsh/.credentials.yaml，模板见 config/credentials.example.yaml

# 3. 部署（幂等，可重复运行）
./scripts/install.sh

# 4. 验证（3080 / 3457 / 3458 + MCP initialize + 工具清单）
./scripts/verify.sh
```

ChatGPT 侧创建连接器（一次性操作）：见 [docs/connector-creation.md](docs/connector-creation.md)。

安装后 watchdog 守护 web、keepalive 守护隧道，崩溃自动恢复，无需手动干预。

## 守护组件

| 组件 | launchd Label | 作用 |
|---|---|---|
| dsh-web-watchdog | `com.dsh-connector.dsh-web-watchdog` | 每 10s 探 3080+3457，连续失败达阈值且数据链确认假死才受控重启 web |
| tunnel-client-keepalive | `com.dsh-connector.tunnel-client-keepalive` | 每 15s 探 3458+3457，隧道挂或 daemon 重启则重建隧道 |
| helm daemon | （由 web 拉起） | agent-chatgpt-helm 的 MCP 服务端，127.0.0.1:3457 |
| tunnel-client | （由 keepalive 拉起） | 隧道客户端，健康端口 3458 |

daemon 不自管隧道（patch `tunnelEnabled: false`），隧道由 keepalive 独占管理，避免双实例抢同一 tunnel。

> 注意：若机器已有其他 LaunchAgent 管理 DSH web，请停用其一再安装（install.sh 会检测并提示）。

## 日常运维

```bash
tail -f ~/.dsh/logs/dsh-web-watchdog.log            # web 守护
tail -f ~/.dsh/logs/tunnel-client-keepalive.log      # 隧道守护
tail -f ~/.dsh/logs/tunnel-client-manual.log         # 隧道客户端

launchctl kickstart -k gui/$(id -u)/com.dsh-connector.tunnel-client-keepalive
launchctl kickstart -k gui/$(id -u)/com.dsh-connector.dsh-web-watchdog
```

## 故障排查

```bash
for p in 3080 3457 3458; do curl -sS --max-time 3 -o /dev/null -w "$p: %{http_code}\n" http://127.0.0.1:$p/healthz; done
```

自愈动作（重启/重建）前会自动落盘诊断快照到 `~/.dsh/logs/diagnostics/`，含进程、端口、日志 tail。症状对照见 [docs/troubleshooting.md](docs/troubleshooting.md)——ChatGPT 侧超时多数是本机故障的下游表现，先查本机再怀疑平台。

## 升级与卸载

```bash
git pull && ./scripts/install.sh        # 升级（幂等）
./scripts/uninstall.sh                  # 卸载（保留凭据/日志）
./scripts/uninstall.sh --purge          # 彻底卸载（连凭据/token/日志一起删）
```

## 开发与测试

```bash
bash tests/run-tests.sh                 # 故障注入测试（隔离端口与临时目录，不影响本机服务）
```

## 文档

- [docs/architecture.md](docs/architecture.md) — 架构与端口说明
- [docs/connector-creation.md](docs/connector-creation.md) — ChatGPT 连接器创建流程
- [docs/verification.md](docs/verification.md) — 验证清单与 MCP 工具列表
- [docs/troubleshooting.md](docs/troubleshooting.md) — 排障手册

## License

[MIT](LICENSE)
