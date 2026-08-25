/**
 * 会话摘要核心：sessions_get 响应瘦身。
 *
 * 病灶：sessions_get 原样返回 DSH 的完整 structuredContent（messages 全量），
 * 大 session 单次响应可达几十上百 KB（实测 75KB+）。
 *
 * 本模块提供两层隔离：
 * - 默认只返回结构化摘要（~KB）：current_goal 行动性排序 / last_user_message /
 *   recent_evidence / history_ref / 凭据清洗；include_messages=true 才走完整历史。
 * - 摘要按 ~/.dsh/connector/summaries/<session_id>.json 缓存（0600，TTL 60s），
 *   命中直接返回、不调 DSH；PROMPT/RESUME/CANCEL 成功后失效。
 *
 * DSH daemon（agent-chatgpt-helm 0.1.1）sessions_get 探测结论（2026-08-24）：
 * 1. inputSchema 仅 { agent?, session_id, max_messages?(1..100) }；未知键被
 *    静默忽略（beforeSeq 无效 → DSH 0.1.1 无真实翻页，history_ref 可达上限 100 条）。
 * 2. 返回 structuredContent.session = { id, agent, status, workspace, title,
 *    updatedAt, messages:[{seq,time,role,text}], lastAssistantText, native }。
 * 3. max_messages 参数有效（不传默认最后 10 条）；无 createdAt / 无 token 统计
 *    → created_at 空串、token 估算（字符数/4）。
 */

import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

/** 摘要文本截断上限（字符）。 */
export const MAX_SUMMARY_CHARS = 300
/** 摘要缓存 TTL（毫秒）。 */
export const SUMMARY_TTL_MS = 60_000
/** 摘要信息来源窗口：向 DSH 取最后 N 条消息。 */
export const SUMMARY_WINDOW = 20
/** 摘要缓存目录（connector 专用，不与其他工具共享）。 */
export const SUMMARY_CACHE_DIR = join(homedir(), '.dsh', 'connector', 'summaries')

/**
 * 有实质内容的 user 消息（current_goal 来源过滤）：长度 >6 且非纯确认词。
 * 注意：确认词必须整串锚定（CJK 文本无 ASCII 词边界，\b 对中文无效）。
 */
export function isSubstantiveUserMessage(text) {
  const t = text.trim()
  if (t.length <= 6) return false
  if (/^(继续|好的?|好|OK|ok|嗯|是的?|对|收到|可以|行|知道了?|了解)[。.!！]?$/.test(t)) return false
  return true
}

/** 显式 next_action/计划信号（+2）。 */
const ACTION_HIGH = /(下一步|接下来|请|待办|记得|马上|立即|务必|优先|请先|先做|现在|马上)/
/** 命令式动词起始（+1）。 */
const ACTION_LOW = /^(实现|修复|处理|生成|检查|更新|补充|运行|跑|执行|创建|删除|改为|改成|继续写|写|调|查|测|测试|部署|提交|推送|合并|解决|优化|重构|清理|验证)/

/**
 * user 消息行动性打分（current_goal 选择依据）：显式 next_action > 命令式动词 > 其余。
 * 同分取更近消息（调用方处理）。无行动性的模板/确认文本不得覆盖明确目标。
 */
export function actionScore(text) {
  const t = text.trim()
  if (ACTION_HIGH.test(t)) return 2
  if (ACTION_LOW.test(t)) return 1
  return 0
}

/** 截断到 max 字符（保留省略号占位）。 */
function truncate(s, max = MAX_SUMMARY_CHARS) {
  if (s.length <= max) return s
  return `${s.slice(0, max)}…`
}

/**
 * 凭据清洗：剔除疑似凭据片段（Bearer、key/token/password/secret 赋值、
 * sk-* 密钥、AKIA AWS key）。用于所有摘要文本字段之前。
 * 清洗目的是"摘要不携带秘密"，不修改 DSH 原始消息。
 */
const SECRET_PATTERNS = [
  /Bearer\s+[A-Za-z0-9._~+/=-]{6,}/gi,
  /\b(?:api[_-]?key|access[_-]?key|token|password|passwd|secret|client[_-]?secret)\s*[:=]\s*[^\s,;"']{6,}/gi,
  /\bsk-[A-Za-z0-9_-]{8,}/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
]
export function sanitizeSecretLines(s) {
  let out = s
  for (const re of SECRET_PATTERNS) out = out.replace(re, '[redacted]')
  return out
}

/** 按候选键名取首个字符串值（DSH 字段名兼容映射）。 */
function stringOf(obj, keys) {
  for (const k of keys) {
    const v = obj[k]
    if (v !== undefined && v !== null) return String(v)
  }
  return undefined
}

function truthy(obj, keys) {
  for (const k of keys) {
    const v = obj[k]
    if (v === true || v === 'true' || v === 1) return true
  }
  return false
}

/** 从 payload（structuredContent）提取消息数组：兼容 {session:{messages}} 与 {messages}。 */
function extractMessages(payload) {
  const session = payload.session
  if (session && typeof session === 'object' && Array.isArray(session.messages)) {
    return session.messages
  }
  if (Array.isArray(payload.messages)) return payload.messages
  return []
}

/**
 * 窗口内启发式提取工程证据（正则去重，每类 ≤3 条；extracted:true 固定标注）。
 */
export function extractEvidence(messages) {
  const commits = []
  const paths = []
  const errors = []
  const tests = []
  const seen = new Set()
  const pushIfNew = (arr, v) => {
    if (v && !seen.has(v) && arr.length < 3) {
      seen.add(v)
      arr.push(v)
    }
  }
  for (const m of messages) {
    const text = sanitizeSecretLines(stringOf(m, ['text']) ?? '')
    // commit hash：必须带 commit 前缀（避免误抓随机 hex）
    for (const mm of text.matchAll(/commit\s+([0-9a-f]{7,40})/g)) {
      pushIfNew(commits, mm[1])
    }
    // 文件/测试路径
    for (const mm of text.matchAll(/\/(?:[\w.-]+\/)*[\w.-]+\.(?:ts|js|py|go|rs|java|md|json|yaml|yml|sh|sql|conf)\b/g)) {
      pushIfNew(paths, mm[0])
    }
    // 错误行（跳过"修复…失败"这类指令文本）
    for (const mm of text.matchAll(/(?:Error|error|ERROR|失败|错误)[^\n]{0,60}/g)) {
      const line = mm[0].trim().slice(0, 80)
      if (/^修复.{0,20}(失败|错误)/.test(line)) continue
      pushIfNew(errors, line)
    }
    // 测试结果
    for (const mm of text.matchAll(/\d+\s+passed[^\n]{0,40}|\d+\s+failed[^\n]{0,40}|PASS[^\n]{0,40}|FAIL[^\n]{0,40}/g)) {
      pushIfNew(tests, mm[0].trim().slice(0, 80))
    }
  }
  return { commits: commits.slice(0, 3), paths: paths.slice(0, 3), errors: errors.slice(0, 3), tests: tests.slice(0, 3), extracted: true }
}

/** token 估算：优先 DSH 真实统计字段，无则字符数/4（估算标记）。 */
function tokenEstimate(session, messages) {
  for (const key of ['tokenUsage', 'token_usage', 'totalTokens', 'total_tokens', 'tokens', 'usage', 'tokenCount']) {
    const v = session[key]
    if (typeof v === 'number' && Number.isFinite(v)) {
      return { token_estimate: Math.round(v), token_estimate_estimated: false }
    }
    if (v && typeof v === 'object') {
      for (const k of ['total_tokens', 'totalTokens', 'total']) {
        if (typeof v[k] === 'number' && Number.isFinite(v[k])) {
          return { token_estimate: Math.round(v[k]), token_estimate_estimated: false }
        }
      }
    }
  }
  const chars = messages.reduce((acc, m) => acc + (typeof m.text === 'string' ? m.text.length : 0), 0)
  return { token_estimate: Math.max(1, Math.round(chars / 4)), token_estimate_estimated: true }
}

/**
 * 会话摘要服务：摘要构建 + 完整历史透传 + 摘要缓存。
 * daemon 提供 callTool(name, args) -> { structuredContent }（mcp-proxy/daemon.mjs）。
 */
export class SessionSummaryService {
  constructor(daemon, opts = {}) {
    this.daemon = daemon
    this.cacheDir = opts.cacheDir ?? SUMMARY_CACHE_DIR
    this.logFn = opts.log
  }

  log(line) {
    this.logFn?.(line)
  }

  /** 统一入口：include_messages=true 走完整历史，否则走摘要（缓存优先）。 */
  async getSession(params) {
    const { session_id, include_messages, max_messages, before_seq } = params
    if (!session_id) throw new Error('sessions_get: missing session_id')
    if (include_messages === true) {
      // 完整历史路径（兼容旧用户）：透传 DSH，限制条数 + 分页参数原样透传
      const res = await this.daemon.callTool('sessions_get', {
        session_id,
        max_messages: max_messages ?? 20,
        beforeSeq: before_seq,
      })
      const base = res.structuredContent ?? (res.content ? { content: res.content } : {})
      // 分页：DSH messages 元素含 seq（探测确认），附带 next_before_seq 供翻页
      const msgs = extractMessages(base)
      if (msgs.length > 0 && msgs.every((m) => typeof m.seq === 'number')) {
        return { ...base, next_before_seq: Math.min(...msgs.map((m) => m.seq)) }
      }
      return base
    }
    // 默认：摘要路径（缓存命中直接返回，不调 DSH）
    const cached = this.readCache(session_id)
    if (cached) return cached
    const summary = await this.buildSummary(session_id)
    const enriched = { ...summary, generated_at: Date.now() }
    this.writeCache(session_id, enriched)
    return enriched
  }

  /** 现场构建摘要：向 DSH 取最后 20 条消息（max_messages 实测有效）。 */
  async buildSummary(sessionId) {
    const res = await this.daemon.callTool('sessions_get', { session_id: sessionId, max_messages: SUMMARY_WINDOW })
    const payload = res.structuredContent ?? {}
    const session = payload.session ?? payload
    const rawMessages = Array.isArray(session.messages) ? session.messages : []
    const messages = rawMessages.length > SUMMARY_WINDOW ? rawMessages.slice(-SUMMARY_WINDOW) : rawMessages
    const status = stringOf(session, ['status']) ?? 'unknown'
    const last = messages[messages.length - 1]
    // current_goal：窗口内「有实质内容」的 user 消息按行动性排序取最高者
    const users = messages.filter((m) => m.role === 'user' && isSubstantiveUserMessage(stringOf(m, ['text']) ?? ''))
    const goalMsg = users.reduce((best, m) => {
      const score = actionScore(stringOf(m, ['text']) ?? '')
      const seq = typeof m.seq === 'number' ? m.seq : -1
      if (!best || score > best.score || (score === best.score && seq >= best.seq)) return { m, score, seq }
      return best
    }, undefined)
    const lastUser = [...messages].reverse().find((m) => m.role === 'user' && isSubstantiveUserMessage(stringOf(m, ['text']) ?? ''))
    const lastAssistant = [...messages].reverse().find((m) => m.role === 'assistant')
    const lastAssistantText = lastAssistant ? stringOf(lastAssistant, ['text']) ?? '' : stringOf(session, ['lastAssistantText']) ?? ''
    const evidence = extractEvidence(messages)
    // 凭据清洗标记：任一窗口消息文本被剔除疑似凭据行
    const sanitized = messages.some((m) => sanitizeSecretLines(stringOf(m, ['text']) ?? '') !== stringOf(m, ['text']))

    return {
      id: stringOf(session, ['id', 'session_id']) ?? sessionId,
      title: sanitizeSecretLines(stringOf(session, ['title']) ?? ''),
      status,
      workspace: sanitizeSecretLines(stringOf(session, ['workspace']) ?? ''),
      created_at: stringOf(session, ['createdAt', 'created_at']) ?? '',
      updated_at: sanitizeSecretLines(stringOf(session, ['updatedAt', 'updated_at']) ?? ''),
      last_message_summary: last ? sanitizeSecretLines(truncate(stringOf(last, ['text']) ?? '')) : '',
      last_assistant_summary: sanitizeSecretLines(truncate(lastAssistantText)),
      current_goal: goalMsg ? sanitizeSecretLines(truncate(stringOf(goalMsg.m, ['text']) ?? '')) : '',
      current_goal_seq: goalMsg && typeof goalMsg.m.seq === 'number' ? goalMsg.m.seq : undefined,
      last_user_message: lastUser ? sanitizeSecretLines(truncate(stringOf(lastUser, ['text']) ?? '')) : '',
      recent_evidence: evidence,
      history_ref: {
        include_messages: true,
        max_messages: SUMMARY_WINDOW,
        before_seq: messages.length > 0 && typeof messages[0]?.seq === 'number' ? messages[0].seq : undefined,
        reachable_max_messages: 100,
        pagination: 'dsh-beforeSeq-unsupported-0.1.1',
      },
      safety_sanitized: sanitized,
      ...tokenEstimate(session, messages),
      continuation_available: status === 'idle' || truthy(session, ['continuation_available', 'canContinue', 'resumable']),
    }
  }

  /** 删除某会话的摘要缓存（PROMPT/RESUME/CANCEL/CREATE 成功后调用）。 */
  invalidate(sessionId) {
    try {
      rmSync(this.cachePath(sessionId), { force: true })
    } catch (err) {
      this.log(`summary cache invalidate failed: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  cachePath(sessionId) {
    return join(this.cacheDir, `${sessionId}.json`)
  }

  /** 读缓存；不存在/损坏/超 TTL 一律未命中（容错，不外抛）。 */
  readCache(sessionId) {
    try {
      const parsed = JSON.parse(readFileSync(this.cachePath(sessionId), 'utf8'))
      if (typeof parsed.generated_at !== 'number') return undefined
      if (Date.now() - parsed.generated_at > SUMMARY_TTL_MS) return undefined
      return parsed
    } catch {
      return undefined
    }
  }

  /** 写缓存（0600，目录自动创建）；失败仅记日志不抛错。 */
  writeCache(sessionId, data) {
    try {
      mkdirSync(this.cacheDir, { recursive: true })
      writeFileSync(this.cachePath(sessionId), JSON.stringify(data, null, 2), { mode: 0o600 })
    } catch (err) {
      this.log(`summary cache write failed: ${err instanceof Error ? err.message : String(err)}`)
    }
  }
}
