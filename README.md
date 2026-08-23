# dsh-chatgpt-connector

让 **ChatGPT 直接操作本机 DeepSeek Harness (DSH)** 的完整部署套件。

ChatGPT 通过 OpenAI 官方 Secure MCP Tunnel 连到本机的 DSH：ChatGPT 负责读代码、规划、审查（Serena 代码智能 + DSH 原生会话），DSH 负责实际执行。整套框架在 macOS 上跑通（已在多台 macOS 机器部署验证）。

```
   ChatGPT（对话里选连接器）
        │  OpenAI Secure MCP Tunnel（控制面 api.openai.com）
        ▼
   tunnel-client（keepalive 守护，3458 健康端口）
        │  本机 MCP（带 Bearer token）
        ▼
   helm daemon（agent-chatgpt-helm，127.0.0.1:3457）
        ├── Serena 代码智能（只读 code_* 工具）
        └── DSH 原生会话（sessions_* 工具 → dsh web 3080）
```

**安全模型**：所有服务只监听 `127.0.0.1`（3080/3457/3458）；ChatGPT 通过隧道反向连回，MCP 调用带 Bearer token；凭据存 `~/.dsh/.credentials.yaml`（0600），不入库。详见 [SECURITY.md](SECURITY.md)。

---

## 目录结构

```
dsh-chatgpt-connector/
├── README.md                  # 本文件：完整部署流程
├── LICENSE                    # MIT License
├── CHANGELOG.md               # 变更记录
├── VERSION                    # 当前版本号
├── SECURITY.md                # 安全模型与漏洞报告
├── scripts/
│   ├── install.sh             # 一键部署（依赖+launchd+patch）
│   ├── uninstall.sh           # 卸载（含 cordis.patch.yml 段精确删除）
│   ├── verify.sh              # 部署后验证（4 层健康 + MCP 握手）
│   ├── tunnel-client-keepalive.sh  # 隧道守护（15s 探针+自动拉起）
│   └── dsh-web-watchdog.sh    # DSH web 守护（受控重启）
├── launchd/                   # LaunchAgent 模板（install.sh 生成实际 plist）
├── patches/
│   └── helm-tunnel.patch.yml  # dsh-chatgpt-helm tunnelEnabled:false 补丁
├── config/
│   └── credentials.example.yaml  # 凭据模板（真实值放 ~/.dsh/.credentials.yaml）
├── docs/
│   ├── architecture.md        # 架构与端口说明
│   ├── connector-creation.md  # ChatGPT 连接器创建流程（重点！）
│   ├── verification.md        # 验证清单与 MCP 工具列表
│   └── troubleshooting.md     # 全量踩坑手册（务必先读）
└── tests/                     # 故障注入测试套件（bash tests/run-tests.sh）
```

---

## 前置条件

| 依赖 | 版本/说明 | 验证 |
|---|---|---|
| macOS | 14+（Apple Silicon；Intel 亦可，tunnel-client 选对应架构） | `sw_vers` |
| Node.js | 22+ | `node --version` |
| DeepSeek Harness | 已 clone 并装好依赖 | `[HARNESS]/.tools/node22/bin/node --version` |
| dsh CLI | 在 PATH | `dsh --version` |
| tunnel-client | OpenAI 官方（见下） | `~/.local/bin/tunnel-client --version` |
| serena | 代码智能 | `serena --help` |
| uv | serena 安装用 | `uv --version` |
| 代理 | Clash Verge 或等价物，监听 `127.0.0.1:7897` | `curl -x http://127.0.0.1:7897 https://api.openai.com` |
| OpenAI Platform 隧道 | 本机专属 tunnel + API key | 见 `docs/connector-creation.md` |

> 全新 Mac 首次 `git clone` 会提示安装 **Xcode Command Line Tools**（自动弹出，同意即可）。

### tunnel-client 获取

`tunnel-client` 是 OpenAI 提供的 Go 二进制（v0.0.12+，控制面 `api.openai.com`，内置 cloudflared）。获取方式（任选）：

- OpenAI Platform 创建 Tunnel 时平台提供下载；
- 官方 GitHub Releases：<https://github.com/openai/tunnel-client/releases/latest>（macOS 选 arm64 / amd64 对应本机架构）；
- Homebrew：`brew install openai/tools/tunnel-client`。

放到 `~/.local/bin/tunnel-client` 并 `chmod +x`。

### serena 安装

```bash
uv tool install -p 3.13 serena-agent
serena init
```

---

## 部署（一步到位）

> 每台机器使用**独立的 Tunnel + 连接器**（一个 tunnel_id 同时只能有一个活跃客户端，多台机器互不干扰）。OpenAI/ChatGPT 侧配置见 [docs/connector-creation.md](docs/connector-creation.md)。

```bash
# 1. 克隆本仓库
git clone https://github.com/lixiaoshuang79/dsh-chatgpt-connector.git ~/deepseek/dsh-chatgpt-connector
cd ~/deepseek/dsh-chatgpt-connector

# 2. 配置凭据（务必参考 docs/connector-creation.md 先建好自己的隧道！）
#    创建/编辑 ~/.dsh/.credentials.yaml，加入：
#      CONTROL_PLANE_TUNNEL_ID: tunnel_xxx
#      CONTROL_PLANE_API_KEY: sk-xxx
#    模板见 config/credentials.example.yaml

# 3. 一键部署
./scripts/install.sh
#    也可指定 DSH checkout 路径：DSH_HARNESS_DIR=/path/to/harness ./scripts/install.sh

# 4. 启动 web（若未运行；install.sh 后 watchdog 约 10-40s 内会自动拉起，本步为手动备选）
cd <deepseek-harness 路径> && .tools/node22/bin/node --import tsx/esm apps/cli/src/bin.ts web --no-open

# 5. 验证
./scripts/verify.sh
#    期望：3080 / 3457 / 3458 全绿 + MCP initialize 握手成功 + supervisor_health ok + 工具清单 ≥19
```

**之后就完事了**——`watchdog` 守护 web，`keepalive` 守护隧道，常驻自愈。

---

## 部署的守护组件

| 组件 | launchd Label | 作用 |
|---|---|---|
| dsh-web-watchdog | `com.dsh-connector.dsh-web-watchdog` | 每 10s 探 3080+3457，连续 3 次双挂才受控重启 web（不误杀） |
| tunnel-client-keepalive | `com.dsh-connector.tunnel-client-keepalive` | 每 15s 探 3458+3457，隧道挂/daemon 重启则重建隧道 |
| helm daemon | （web 拉起） | agent-chatgpt-helm 的 MCP 服务端，127.0.0.1:3457 |
| tunnel-client | （keepalive 拉起） | 隧道客户端，健康端口 3458 |

关键设计：**daemon 不自管隧道**（patch `tunnelEnabled: false`），隧道由 keepalive 独占管理——避免双实例抢同一 tunnel 互相 pkill。

> ⚠️ 如果你的机器已有其他 LaunchAgent 管理 DSH web（如 `com.deepseek.dsh`），请停用其一再装本套件（install.sh 会检测并提示），否则 watchdog 与它会并发拉起 web（3080 端口冲突）。

---

## ChatGPT 侧（一次性）

> UI 免责：OpenAI 产品界面持续变化（2025-10「GPTs → ChatGPT apps」改名；Chat/Work 双标签；2026 有合并 tab 预告）。以下基于 2026-08 实测；官方指南见 <https://developers.openai.com/api/docs/guides/secure-mcp-tunnels>。

1. 在 [OpenAI Platform](https://platform.openai.com/settings/organization/tunnels) 创建 **Secure MCP Tunnel** 并下载 tunnel-client（或 [GitHub Releases](https://github.com/openai/tunnel-client/releases/latest) / `brew install openai/tools/tunnel-client`）；创建 **Runtime API key**（Restricted：Tunnels Read + Tunnels Use）。详见 [docs/connector-creation.md](docs/connector-creation.md)。
2. 在 <https://chatgpt.com/plugins>（需 **Developer mode**：Settings → Security and login）创建 App：
   - 类型选 **Tunnel**，选你建好的 Tunnel，填名（如 `dsh-helm-company`）
   - Auth 选 **No Authentication**（官方选项：OAuth / No Authentication / Mixed），勾选风险确认 → **Create**
   - 出现工具列表后点 **Connect** → 弹窗 **Add to ChatGPT** 确认
3. 打开 ChatGPT，对话里选该连接器，即可看到 DSH 的 19 个工具（8 个 `code_*` 读代码含工作区激活 + 11 个 `projects/supervisor/agents/workspaces/sessions_*` 执行）。写操作（如 sessions_prompt）默认需确认。

> ⚠️ 创建连接器时隧道必须健康（3458 通、tunnel-client 在跑）。隧道不健康时创建会得到「Installed 但 plugin_not_found」的半成品，需 Plugin actions → Uninstall 后重建。

---

## 日常运维

```bash
# 看日志
tail -f ~/.dsh/logs/dsh-web-watchdog.log            # web 守护
tail -f ~/.dsh/logs/tunnel-client-keepalive.log      # 隧道守护
tail -f ~/.dsh/logs/tunnel-client-manual.log         # 隧道客户端本身

# 手动拉一次隧道（keepalive 异常时）
bash ~/.local/bin/tunnel-client run \
  --control-plane.tunnel-id "$CONTROL_PLANE_TUNNEL_ID" \
  --control-plane.api-key env:CONTROL_PLANE_API_KEY \
  --control-plane.poll-timeout=10000ms \
  --control-plane.poll-deadline-guardrail=3000ms \
  --mcp.server-url http://127.0.0.1:3457/mcp \
  --mcp.extra-headers "Authorization: env:AGENT_CHATGPT_HELM_AUTH" \
  --health.listen-addr 127.0.0.1:3458 &

# 重启组件
launchctl kickstart -k gui/$(id -u)/com.dsh-connector.tunnel-client-keepalive
launchctl kickstart -k gui/$(id -u)/com.dsh-connector.dsh-web-watchdog
```

## 故障诊断（先看这里）

DSH 出现「挂了 / 没响应」时，按顺序排查：

```bash
# 1. 三端口健康（3080 web / 3457 MCP daemon / 3458 隧道）
for p in 3080 3457 3458; do echo -n "$p: "; curl -sS --max-time 3 -o /dev/null -w "%{http_code} %{time_total}s" http://127.0.0.1:$p/healthz; echo; done

# 2. 关键进程是否存活
ps aux | grep -E "bin\.ts web|cli\.js daemon|tunnel-client run" | grep -v grep

# 3. 守护日志（看故障前最后动作）
tail -50 ~/.dsh/logs/dsh-web-watchdog.log        # web 守护（重启/保护记录）
tail -50 ~/.dsh/logs/tunnel-client-keepalive.log # 隧道守护（重建记录）
tail -50 ~/.dsh/logs/helm-daemon.log             # MCP daemon（adapter 注册/断开）
tail -50 ~/.dsh/logs/tunnel-client-manual.log    # 隧道客户端（ChatGPT 请求流）

# 4. 自愈快照（重启/重建前自动落盘，含进程+端口+日志 tail）
ls -lt ~/.dsh/logs/diagnostics/   # 最近一次故障现场
cat ~/.dsh/logs/diagnostics/<最新时间戳>/meta.txt
cat ~/.dsh/logs/diagnostics/<最新时间戳>/state.txt
```

**故障域速判**（对照快速定位）：

| 症状 | 故障域 | 处理 |
|---|---|---|
| 3080 超时但 3457/3458 正常，日志有「datapath stall」 | web 假死（事件循环阻塞） | 0.1.1+ watchdog：MCP initialize + `sessions_list` 探测数据链——无活跃会话连续 2 轮 stall 自动重启；有活跃会话保护 300s（`WATCH_ACTIVE_STALL_GRACE_SEC`）后仍 stall 才重启 |
| keepalive 日志刷「检测到 helm daemon 重启」且 15s 一次 | daemon 反复重启 / PID 探测抖动 | 看 helm-daemon.log 是否 adapter 反复断开；0.1.1+ 已加限速防抖 |
| 3458 通但 ChatGPT 连不上 | 隧道控制面断（代理失效） | 确认 7897 代理；tunnel-client-manual.log 看 poller 是否 stopped |
| 3457 超时但 3080 正常 | daemon 卡死 | watchdog 会自动重启 web 连带 daemon |
| 3080/3457 都通但 ChatGPT 任务静默丢失 | 隧道被反复重建（旧版 keepalive 死循环） | 升级到 0.1.1+（daemon-down 守卫 + 限速） |

**ChatGPT 侧超时/丢失**多数是上述前端的下游表现（web 假死或隧道重建导致请求挂起），先查本机再怀疑平台。

## 升级与卸载

```bash
# 升级：拉新代码后重跑 install（plist 重建 + job 重启，幂等）
git pull
./scripts/install.sh

# 卸载（保留凭据/日志）
./scripts/uninstall.sh

# 彻底卸载（连凭据/token/日志一起删）
./scripts/uninstall.sh --purge
```

## 开发与测试

```bash
# 全量故障注入测试（37 断言；隔离端口与临时目录，不影响本机服务）
bash tests/run-tests.sh

# 单套件
bash tests/test-keepalive.sh
```

测试用真实 HTTP 端点 + fake 二进制模拟守护场景（daemon 重启/隧道挂/高负载/残留清理），不碰实际运行环境进程与端口。

完整架构说明见 `docs/architecture.md`，连接器创建细节见 `docs/connector-creation.md`，验证清单见 `docs/verification.md`，**所有踩过的坑见 `docs/troubleshooting.md`**。