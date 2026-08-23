# dsh-chatgpt-connector

让 **ChatGPT 直接操作本机 DeepSeek Harness (DSH)** 的完整部署套件。

ChatGPT 通过 OpenAI 官方 Secure MCP Tunnel 连到本机的 DSH：ChatGPT 负责读代码、规划、审查（Serena 代码智能 + DSH 原生会话），DSH 负责实际执行。整套框架在 macOS 上稳定跑通（多台 macOS 机器部署验证）。

```
   ChatGPT（对话里选连接器）
        │  OpenAI Secure MCP Tunnel（控制面 api.openai.com）
        ▼
   tunnel-client（tunnel-client 守护，3458 健康端口）
        │  本机 MCP（带 Bearer token）
        ▼
   helm daemon（agent-chatgpt-helm，127.0.0.1:3457）
        ├── Serena 代码智能（只读 code_* 工具）
        └── DSH 原生会话（sessions_* 工具 → dsh web 3080）
```

---

## 目录结构

```
dsh-chatgpt-connector/
├── README.md                  # 本文件：完整部署流程
├── scripts/
│   ├── install.sh             # 一键部署（依赖+launchd+patch）
│   ├── verify.sh              # 部署后验证（4 层健康）
│   ├── tunnel-client-keepalive.sh  # 隧道守护 v2（15s 探针+自动拉起）
│   └── dsh-web-watchdog.sh    # DSH web 守护 v2（受控重启）
├── launchd/                   # LaunchAgent 模板（install.sh 生成实际 plist）
├── patches/
│   └── helm-tunnel.patch.yml  # dsh-chatgpt-helm tunnelEnabled:false 补丁
├── config/
│   └── credentials.example.yaml  # 凭据模板（含真实值后放 ~/.dsh/.credentials.yaml）
├── docs/
│   ├── architecture.md        # 架构与端口说明
│   ├── connector-creation.md  # ChatGPT 连接器创建流程（重点！）
│   ├── verification.md        # 验证清单与 MCP 工具列表
│   └── troubleshooting.md     # 全量踩坑手册（务必先读）
└── tests/                     # 故障注入测试套件（bash -c tests/run-tests.sh）
```

---

## 前置条件

| 依赖 | 版本/说明 | 验证 |
|---|---|---|
| macOS | 14+ | `sw_vers` |
| Node.js | 22+ | `node --version` |
| DeepSeek Harness | 已 clone 并装好依赖 | `[HARNESS]/.tools/node22/bin/node --version` |
| dsh CLI | 在 PATH | `dsh --version` |
| tunnel-client | OpenAI 官方（见下） | `~/.local/bin/tunnel-client --version` |
| serena | 代码智能 | `serena --help` |
| 代理 | Clash Verge 或等价物，监听 `127.0.0.1:7897` | `curl -x http://127.0.0.1:7897 https://api.openai.com` |
| OpenAI Platform 隧道 | 本机专属 tunnel + API key | 见 `docs/connector-creation.md` |

### tunnel-client 获取

`tunnel-client` 是 OpenAI 提供的 Go 二进制（v0.0.12 +，控制面 `api.openai.com`，内置 cloudflared）。在 OpenAI Platform 创建 Tunnel 时平台提供下载；或找已装好的机器拷贝 `~/.local/bin/tunnel-client`（单文件，macOS arm64 直接可用）。放到 `~/.local/bin/tunnel-client` 并 `chmod +x`。

### serena 安装

```bash
uv tool install -p 3.13 serena-agent
serena init
```

---

## 部署（多台机器，一步到位）

```bash
# 1. 克隆本仓库
git clone git@github.com:lixiaoshuang79/dsh-chatgpt-connector.git ~/deepseek/dsh-chatgpt-connector
cd ~/deepseek/dsh-chatgpt-connector

# 2. 配置凭据（务必参考 docs/connector-creation.md 先建好自己的隧道！）
#    创建/编辑 ~/.dsh/.credentials.yaml，加入：
#      CONTROL_PLANE_TUNNEL_ID: tunnel_xxx
#      CONTROL_PLANE_API_KEY: sk-xxx
#    模板见 config/credentials.example.yaml

# 3. 一键部署
./scripts/install.sh
#    也可指定 DSH checkout 路径：DSH_HARNESS_DIR=/path/to/harness ./scripts/install.sh

# 4. 启动 web（若未运行）
cd ~/deepseek/deepseek-harness && .tools/node22/bin/node --import tsx/esm apps/cli/src/bin.ts web --no-open

# 5. 验证
./scripts/verify.sh
#    期望：3080 / 3457 / 3458 全绿 + supervisor_health ok + 工具清单 ≥19
```

**之后就完事了**——`watchdog` 守护 web，`keepalive` 守护隧道，两台都常驻自愈。

---

## 部署的四个守护组件

| 组件 | launchd Label | 作用 |
|---|---|---|
| dsh-web-watchdog | `com.dsh-connector.dsh-web-watchdog` | 每 10s 探 3080+3457，连续 3 次双挂才受控重启 web（不误杀） |
| tunnel-client-keepalive | `com.dsh-connector.tunnel-client-keepalive` | 每 15s 探 3458+3457，隧道挂/daemon 重启则重建隧道 |
| helm daemon | （web 拉起） | agent-chatgpt-helm 的 MCP 服务端，127.0.0.1:3457 |
| tunnel-client | （keepalive 拉起） | 隧道客户端，健康端口 3458 |

关键设计：**daemon 不自管隧道**（patch `tunnelEnabled: false`），隧道由 keepalive 独占管理——避免双实例抢同一 tunnel 互相 pkill。

---

## ChatGPT 侧（一次性）

1. 在 [OpenAI Platform](https://platform.openai.com) `https://platform.openai.com/chatgpt/connectors/plugins`（需 **Developer mode**）创建 App：
   - 类型选 **Tunnel**，选你建好的 Tunnel，填名（如 `dsh-helm-company`）
   - Auth 选 **No Auth**，勾选风险确认 → **Create**
   - 出现工具列表后点 **Connect** → 弹窗 **Add to ChatGPT** 确认
2. 打开 ChatGPT，对话里选该连接器，即可看到 DSH 的 19 个工具（8 个 `code_*` 读代码含工作区激活 + 11 个 `projects/supervisor/agents/workspaces/sessions_*` 执行）。

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

完整架构说明见 `docs/architecture.md`，连接器创建细节见 `docs/connector-creation.md`，验证清单见 `docs/verification.md`，**所有踩过的坑见 `docs/troubleshooting.md`**。