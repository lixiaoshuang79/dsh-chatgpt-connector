# ChatGPT 连接器创建流程（每个部署机器：独立隧道）

> 每台机器建议使用**独立 Tunnel + 独立连接器**——两个 tunnel 互不干扰，多台机器可同时在线。
> 一个 tunnel_id 同时只能有一个活跃 tunnel-client，因此不要在多台机器上复用同一个 tunnel_id。

## 总览

```
OpenAI Platform（https://platform.openai.com/chatgpt/connectors/plugins）
  ├─ 1. 创建 Secure MCP Tunnel → 得到 tunnel_id（tunnel_xxx）
  ├─ 2. 创建 Runtime API Key（Tunnels Read + Tunnels Use）
  ├─ 3. 在 ChatGPT 侧创建 App（连接器）→ 选该 Tunnel → No Auth → Create
  └─ 4. Connect → Add to ChatGPT → 对话里出现 DSH 工具
本机侧
  └─ 把 tunnel_id + api_key 写进 ~/.dsh/.credentials.yaml → keepalive 拉起 tunnel-client
```

## 步骤

### 1. 创建 Tunnel

1. 打开 [OpenAI Platform](https://platform.openai.com) → 左侧 **Tunnels**（或 Chat 相关菜单里的 Tunnel 管理页）。
2. **Create Tunnel**，填写名称（建议 `dsh-helm-company`），创建后得到 `tunnel_xxxxxxxx...`。
3. 平台会提供 **tunnel-client** 下载（oai-tunnel-client）。下载 macOS arm64 版，放到 `~/.local/bin/tunnel-client`，`chmod +x`。

### 2. 创建 API Key

1. Platform → **API keys** → Create new secret key。
2. 权限：**Tunnels Read** + **Tunnels Use**（Runtime 级权限）。
3. 保存 `sk-...`（只显示一次）。

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
# 等 keepalive 拉起，或手动验证：
./scripts/verify.sh
# 3458 必须通（tunnel-client 健康端口）
curl -s http://127.0.0.1:3458/healthz
```

### 5. ChatGPT 侧创建连接器（关键流程）

1. 打开 `https://platform.openai.com/chatgpt/connectors/plugins`。
2. **确认右上角 Developer mode 已开**（没有 Developer mode 就没有 Create app 按钮）。
3. **Create app**：
   - 类型选 **Tunnel**
   - 选你刚建的 Tunnel（`dsh-helm-company`）
   - 填 App 名称（如 `dsh-helm-company`）
   - Auth 选 **No Auth**
   - 勾选风险确认（大意：此 app 可访问你的文件/代码，风险自担）
   - **Create**
4. 创建成功后会列出工具清单（19 个：code_* + sessions_*/supervisor_*）。
5. 点 **Connect**（或 Installed 状态下打开连接器详情）。
6. 弹出 **Add to ChatGPT** 确认框 → 确认。**到这一步才算真正启用**。

### 6. 使用

打开 ChatGPT（注意 **Chat / Work 标签**：Work 标签额度耗尽会锁 composer）：
- 输入框是 ProseMirror contenteditable：`div[contenteditable=true][aria-label="Chat with ChatGPT"]`
- 对话里选择连接器，然后正常提问即可。工具调用会显示在回复里。

---

## 踩坑记录（务必读）

| 现象 | 原因 | 解法 |
|---|---|---|
| 创建后显示「Installed 但 plugin_not_found」半成品 | 创建时隧道不健康（tunnel-client 没跑 / 3458 不通），平台探测失败返回 424 | 先修好隧道（verify.sh 全绿），Plugin actions → **Uninstall** → 重新走创建流程 |
| Connect 后对话里看不到工具 | 连接器未真正 Add to ChatGPT / 隧道断 | 确认 Add to ChatGPT 弹窗已确认；重跑 verify.sh；必要时 Uninstall 重建 |
| ChatGPT 探测失败 / 工具列表为空 | tunnel-client 没带代理，控制面轮询超时 | 确认 7897 代理可用；keepalive 已注入代理；看 tunnel-client-manual.log 有无 poller stopped |
| 两台机器同时用同一 tunnel_id | 隧道是单客户端模型 | 多台机器另建独立 tunnel（本流程）；别复用本机 tunnel_id |
| Create app 按钮不存在 | 没开 Developer mode | Platform 右上角打开 Developer mode |
