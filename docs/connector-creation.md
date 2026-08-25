# ChatGPT 连接器创建流程（每个部署机器：独立隧道）

> 每台机器建议使用**独立 Tunnel + 独立连接器**——两个 tunnel 互不干扰，多台机器可同时在线。
> 一个 tunnel_id 同时只能有一个活跃 tunnel-client，因此不要在多台机器上复用同一个 tunnel_id。

> **UI 免责**：OpenAI/ChatGPT 的产品界面持续变化（2025-10「GPTs → ChatGPT apps」改名；Chat/Work 双标签；2026 有合并 tab 的预告）。以下流程基于 2026-08 的界面编写，若界面有出入，以官方入口为准：Secure MCP Tunnel 官方指南 <https://developers.openai.com/api/docs/guides/secure-mcp-tunnels>。

## 总览

```
OpenAI Platform（https://platform.openai.com/settings/organization/tunnels）
  ├─ 1. 创建 Secure MCP Tunnel → 得到 tunnel_id（tunnel_xxx）
  ├─ 2. 创建 Runtime API Key（Restricted：Tunnels Read + Tunnels Use）
  ├─ 3. 本机把 tunnel_id + api_key 写进 ~/.dsh/.credentials.yaml
  ├─ 4. keepalive 拉起 tunnel-client → 3458 健康
  └─ 5. ChatGPT 侧创建 App（连接器）→ 选该 Tunnel → No Auth → Connect → Add to ChatGPT
```

## 步骤

### 1. 创建 Tunnel

1. 打开 [OpenAI Platform → Tunnels](https://platform.openai.com/settings/organization/tunnels)。
2. **Create Tunnel**，填写名称（建议 `dsh-helm-<机器名>`），创建后得到 `tunnel_xxxxxxxx...`（`tunnel_` + 32 位 hex）。
3. 平台提供 **tunnel-client** 下载；也可用官方发行渠道：
   - GitHub Releases：<https://github.com/openai/tunnel-client/releases/latest>（v0.0.12+，含 macOS arm64）
   - Homebrew：`brew install openai/tools/tunnel-client`
4. 下载后放到 `~/.local/bin/tunnel-client`，`chmod +x`。

### 2. 创建 Runtime API Key

1. Platform → [API keys](https://platform.openai.com/settings/organization/api-keys) → **Create new secret key**。
2. 类型选 **Runtime API keys**（不是 Project/Organization key）。
3. 权限设为 **Restricted**，勾选 **Tunnels Read** + **Tunnels Use**。
4. 保存 `sk-...`（只显示一次，丢失需重建）。

### 3. 本机写入凭据

```bash
cat >> ~/.dsh/.credentials.yaml <<'EOF'
CONTROL_PLANE_TUNNEL_ID: tunnel_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
CONTROL_PLANE_API_KEY: sk-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
EOF
chmod 600 ~/.dsh/.credentials.yaml
```

> 两个值同时存在，keepalive 才会拉起隧道。**任何一步缺了，隧道就不会启动**（keepalive 日志会写「凭据缺失」）。

### 4. 启动隧道并验证健康

```bash
./scripts/verify.sh
# 3458 必须通（tunnel-client 健康端口）
curl -s http://127.0.0.1:3458/healthz
```

### 5. ChatGPT 侧创建连接器（关键流程）

1. 打开 <https://chatgpt.com/plugins>（ChatGPT 内入口；旧地址 `platform.openai.com/chatgpt/connectors/plugins` 可能仍可用）。
2. **确认右上角 Developer mode 已开**（Settings → Security and login 里的 Developer mode 开关；需 Plus/Pro/Business/Enterprise/Edu 订阅）。没有 Developer mode 就没有 Create app 按钮。
3. **Create app**：
   - 类型选 **Tunnel**
   - 选你刚建的 Tunnel
   - 填 App 名称（如 `dsh-helm-<你的标识>`）
   - Auth 选 **No Authentication**（官方选项：OAuth / No Authentication / Mixed）
   - 勾选风险确认（大意：此 app 可访问你的文件/代码，风险自担）
   - **Create**
4. 创建成功后会列出工具清单（19 个：code_* + sessions_*/supervisor_*）。
5. 点 **Connect**（或 Installed 状态下打开连接器详情）。
6. 弹出 **Add to ChatGPT** 确认框 → 确认。**到这一步才算真正启用**。

### 6. 使用

打开 ChatGPT（注意 **Chat / Work 标签**：Work 标签额度耗尽会锁 composer）：
- 对话输入框是 ProseMirror contenteditable：`div[contenteditable=true][aria-label="Chat with ChatGPT"]`
- 对话里选择连接器（Plus 菜单 → Developer mode → 选 apps），然后正常提问即可。工具调用会显示在回复里；写操作（如 sessions_prompt）默认需要确认。

---

## 升级后：ChatGPT 侧配置（v0.2.0 mcp-proxy）

> 一句话结论：**ChatGPT/OpenAI 侧零改动**。升级（`./scripts/install.sh`）只动本机——
> tunnel_id、连接器、App 全部不变，`install.sh` 自动把 tunnel 的 server-url
> 从 daemon(3457) 切到 mcp-proxy(3461)。新部署走本流程也无需任何额外步骤。

链路变化（对 ChatGPT 透明）：

```
升级前：ChatGPT → tunnel(3458) → helm daemon(3457)
升级后：ChatGPT → tunnel(3458) → mcp-proxy(3461) → helm daemon(3457)
```

### 自动生效（无需配置）

| 能力 | 触发 | ChatGPT 侧可见效果 |
|---|---|---|
| 内容瘦身 | `sessions_get` 默认返回结构化摘要 | 大会话不再整体抛给模型（~KB 摘要：current_goal/最近证据/凭据已清洗） |
| 响应守卫 | 任何工具响应 >50KB | 统一截断为合法 JSON（`truncated` 元数据），对话不会因超大响应卡住 |

### 插队机制（显式触发）

ChatGPT 对话发出的消息不带 `mode=steer`（走 daemon 原生排队语义，与升级前一致）；
要**立即打断运行中的 DSH 会话**，带 `mode=steer` 调用即可，代理自动接管：

```bash
# 会话 id 从 3080 会话列表（或 sessions_list）拿
curl -s -H 'Content-Type: application/json' -X POST http://127.0.0.1:3461/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sessions_prompt","arguments":{"session_id":"<会话id>","message":"先跑 lint 再提交","mode":"steer"}}}'
```

返回 `{"status":"steered",...}`=已注入运行中回合；`queued`=排队；
`rejected`=DSH 拒绝（带 code）；`unavailable`=宿主 API 不可达（链路断，queue 照常）。

### 验证升级生效

```bash
./scripts/verify.sh          # 多一行：✓ mcp-proxy (3461 /healthz)
tail -5 ~/.dsh/logs/mcp-proxy.out   # 启动日志：MCP proxy listening on 127.0.0.1:3461/mcp
```

### 临时绕过代理

把 `~/Library/LaunchAgents/com.dsh-connector.tunnel-client-keepalive.plist` 里的
`HELM_MCP_PORT` 改回 `3457`，重启 keepalive（`launchctl kickstart -k gui/$(id -u)/com.dsh-connector.tunnel-client-keepalive`）。

## 踩坑记录

| 现象 | 原因 | 解法 |
|---|---|---|
| 创建后显示「Installed 但 plugin_not_found」半成品 | 创建时隧道不健康（tunnel-client 没跑 / 3458 不通），平台探测失败返回 424 | 先修好隧道（verify.sh 全绿），Plugin actions → **Uninstall** → 重新走创建流程 |
| Connect 后对话里看不到工具 | 连接器未真正 Add to ChatGPT / 隧道断 | 确认 Add to ChatGPT 弹窗已确认；重跑 verify.sh；必要时 Uninstall 重建 |
| ChatGPT 探测失败 / 工具列表为空 | tunnel-client 没带代理，控制面轮询超时 | 确认 7897 代理可用；keepalive 已注入代理；看 tunnel-client-manual.log 有无 poller stopped |
| 两台机器同时用同一 tunnel_id | 隧道是单客户端模型 | 每台机器另建独立 tunnel（本流程）；别复用 |
| Create app 按钮不存在 | 没开 Developer mode | Settings → Security and login 打开 Developer mode（需付费订阅） |
