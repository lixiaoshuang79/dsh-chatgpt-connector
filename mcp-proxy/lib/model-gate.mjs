/**
 * Model declaration gate：ChatGPT 链路模型门禁（声明式）——单机版移植。
 *
 * 背景（2026-08-25 实测，与 dsh-helm 同源）：ChatGPT 网页版 → Secure MCP
 * Tunnel 的请求不带任何模型信息（OpenAI tunnel 协议无 model 字段），链路层
 * 无法感知调用方模型。因此采用声明式协议：ChatGPT 侧系统指令约束其每次下发
 * 指令时在消息第一行固定声明当前模型名，本代理在路由前校验：
 *
 * - 消息含允许标识（gpt-5-6-thinking / gpt-5.6 thinking 等）→ 放行；
 * - 消息含 5.5-mini 标识 → 拒绝 `model_rejected`（附 received 原文）；
 * - 消息无任何模型声明 → 拒绝 `model_declaration_required`。
 *
 * 被拒响应为 MCP result {content, isError:true} + JSON 文本
 * {code, required_model, received?, message}，ChatGPT 可读原因并按提示
 * 切换模型后重试。
 */

/** 允许的模型标识（GPT-5.6 Thinking；宽松匹配各分隔符变体）。 */
const ALLOWED_RE = /gpt[\s_.-]*5[\s_.-]*6[\s_.-]*thinking/i
/** 明确拒绝的模型标识（GPT-5.5 Mini 系）。 */
const REJECTED_RE = /5[\s_.-]*5[\s_.-]*mini/i

export const REQUIRED_MODEL = 'gpt-5-6-thinking'

/** 需要模型声明门禁的工具（消息注入入口；与 dsh-helm hub 对齐）。 */
export const MODEL_GATED_TOOLS = new Set(['sessions_create', 'sessions_prompt'])

/** 校验一条待注入 DSH 的消息是否带允许的模型声明。 */
export function checkModelDeclaration(message) {
  const text = String(message ?? '')
  if (ALLOWED_RE.test(text)) return { ok: true }
  const m = REJECTED_RE.exec(text)
  if (m) return { ok: false, code: 'model_rejected', received: m[0] }
  return { ok: false, code: 'model_declaration_required' }
}

/** 生成 MCP 拒绝响应文本（结构化，ChatGPT 可读）。 */
export function rejectionText(r) {
  if (r.code === 'model_rejected') {
    return JSON.stringify({
      code: 'model_rejected',
      required_model: REQUIRED_MODEL,
      received: r.received,
      message: `[模型门禁拒绝] 本次指令未执行：ChatGPT 当前模型为「${r.received}」，不是要求的 ${REQUIRED_MODEL}（GPT-5.6 Thinking）。请切换到 GPT-5.6 Thinking 模型后，以 "[model-check] 当前模型是 gpt-5-6-thinking" 开头重发同一指令。`,
    })
  }
  return JSON.stringify({
    code: 'model_declaration_required',
    required_model: REQUIRED_MODEL,
    message: `[模型门禁拒绝] 本次指令未执行：消息中未声明 ChatGPT 模型。请在消息第一行声明 "[model-check] 当前模型是 <模型全名>"（必须是 ${REQUIRED_MODEL} / GPT-5.6 Thinking）后重发同一指令。`,
  })
}

/** 取工具调用里待注入的消息文本（无消息字段返回 null；门禁只拦注入入口）。 */
export function gateMessageArg(name, args) {
  if (name === 'sessions_prompt') return args?.message
  if (name === 'sessions_create') return args?.initial_message
  return null
}