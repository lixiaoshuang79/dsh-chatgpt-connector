# 模型门禁：ChatGPT 侧必须声明模型（5.5-mini 拒绝 / GPT-5.6 Thinking 放行）

> 2026-08-25 建立，与 dsh-helm 同源（hub 侧同样实现）。单机链路由 mcp-proxy 拦截校验。

## 为什么需要

ChatGPT 网页版 → Secure MCP Tunnel → tunnel-client → mcp-proxy 的请求**不带任何模型信息**（OpenAI tunnel 协议无 model 字段，已协议文档 + 实测请求头双重确认）。链路层无法感知调用方模型，因此采用**声明式协议**：

- ChatGPT 侧系统指令约束：每次下发指令时，在**消息第一行**固定声明当前模型名
- mcp-proxy 在路由前校验声明：`gpt-5-6-thinking`（GPT-5.6 Thinking）与 `gpt-5-6-sol`（GPT-5.6 Sol）放行；`5.5-mini` 拒绝；无声明拒绝

## 被拒响应（ChatGPT 端可见）

拒绝时返回 MCP `isError: true` + 结构化 JSON 文本，ChatGPT 工具错误里直接可读：

```json
{
  "code": "model_rejected",
  "required_model": "gpt-5-6-thinking",
  "received": "5.5-mini",
  "message": "[模型门禁拒绝] 本次指令未执行：ChatGPT 当前模型为「5.5-mini」，不是要求的 gpt-5-6-thinking（GPT-5.6 Thinking）。请切换到 GPT-5.6 Thinking 模型后，以 \"[model-check] 当前模型是 gpt-5-6-thinking\" 开头重发同一指令。"
}
```

无声明时 `code: "model_declaration_required"`，提示在消息第一行声明 `[model-check] 当前模型是 <模型全名>`。

## ChatGPT 侧配置（一次性）

在 ChatGPT **Settings → Personalization → Custom instructions** 粘贴以下模板：

```
重要规则：每次回复或调用工具时，必须在消息第一行固定写：
[model-check] 当前模型是 <你的模型全名>

<你的模型全名> 必须是以下两种之一：
- 你当前实际运行的模型全名（如 gpt-5-6-thinking 或 5.5-mini）
- 不准编造、不准省略、不准写成其他名字

如果你实际是 GPT-5.6 Thinking，第一行写：
[model-check] 当前模型是 gpt-5-6-thinking

如果你实际是 5.5-mini，第一行写：
[model-check] 当前模型是 5.5-mini

注意：模型名必须照实声明，声明错误会导致指令被 DSH 拒绝执行。
```

配置后 ChatGPT 每条消息**自动**带声明，无需手动操作：
- 网页上选 GPT-5.6 Thinking / GPT-5.6 Sol → 声明 `gpt-5-6-thinking` / `gpt-5-6-sol` → 放行
- 网页上选了 5.5-mini（或模型被降级）→ 照实声明 `5.5-mini` → 门禁拒绝，ChatGPT 端直接看到拒绝提示

## 实现与验证

- `mcp-proxy/lib/model-gate.mjs`：`checkModelDeclaration` / `rejectionText` / `gateMessageArg`（零依赖）
- `mcp-proxy/server.mjs` `handleToolCall`：门禁拦截在最前，只拦消息注入工具（`sessions_create` / `sessions_prompt`，含 `mode=steer` 插队路径），非注入工具（`sessions_get` 等）不受影响
- 验证：`node --test tests/test-proxy.mjs`（门禁用例：无声明拒绝 / 5.5-mini 拒绝附 received / 放行透传 / 非注入工具不受门禁 / 被拒不落 daemon）
