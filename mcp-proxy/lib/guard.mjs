/**
 * Response size guard：每条工具响应在离开代理前都经过 applyGuard()。
 * - text ≤ MAX_RESPONSE_BYTES（UTF-8 字节数）→ 原样直通（返回原引用）；
 * - 超限且 text 是合法 JSON → smart truncate：优先收窄最大的内容类字符串
 *   字段、宽度型载荷按比例砍尾部元素，挂 `truncated: { original_size,
 *   returned_size, tool }` 元数据——返回文本必须仍是合法 JSON（硬要求）；
 * - 超限且 text 不可解析（纯文本）→ UTF-8 边界安全截断 + 标记。
 *
 * 本 guard 是兜底防线：sessions_get 默认摘要瘦身是第一道防线，
 * 任何工具响应超限最终都会在这里被处理。
 */

/** 单条 MCP 工具响应文本的字节上限（UTF-8）。 */
export const MAX_RESPONSE_BYTES = 50_000

/** JSON 载荷里语义上"内容类"的字段名（同量级大小时优先截这些）。 */
const CONTENT_KEYS = new Set(['text', 'content', 'message', 'summary', 'output', 'body', 'description', 'reply', 'error', 'title', 'name', 'path'])

/** 字符串字段截断后的内联后缀。 */
const FIELD_SUFFIX = '...[truncated]'

/** 每次收窄预留的余量：回填 returned_size 时数字位数变化最多 ~9 字节。 */
const SLACK_BYTES = 64

/** 结构化截断最大迭代次数（防病态形状空转）。 */
const MAX_ITERATIONS = 24

/**
 * 对一条 MCP 调用结果应用尺寸护栏。未超限返回原对象引用；超限返回截断后
 * 的新对象（content[0].text 为最终文本）。
 */
export function applyGuard(result, tool, log) {
  const content = result.content
  const text = content[0]?.text
  // 所有响应都只有一条 text content；缺失时无物可护。
  if (text === undefined) return result
  const original = Buffer.byteLength(text)
  if (original <= MAX_RESPONSE_BYTES) return result

  let finalText
  const parsed = safeParse(text)
  if (parsed.ok) {
    // 原 text 是合法 JSON：截断后必须仍是合法 JSON（connector 硬依赖）。
    finalText = smartTruncateJson(parsed.value, tool, original)
  } else {
    finalText = truncatePlainText(text, original)
  }
  const returned = Buffer.byteLength(finalText)
  log?.(`[mcp-guard] ${tool} original=${original} returned=${returned} truncated`)
  return { ...result, content: [{ ...content[0], text: finalText }] }
}

// ---------------------------------------------------------------------------
// JSON smart truncate
// ---------------------------------------------------------------------------

/**
 * JSON 结构化截断，返回序列化文本（indent=2），保证：
 * 1) 字节数 ≤ MAX_RESPONSE_BYTES；2) 可 JSON.parse；3) 带 truncated 元数据。
 */
function smartTruncateJson(data, tool, originalBytes) {
  let root = data
  if (!isObject(data) && !Array.isArray(data)) {
    root = { value: data }
  } else if (Array.isArray(data)) {
    root = { data }
  }
  const rootObj = root
  const meta = { original_size: originalBytes, returned_size: 0, tool }
  rootObj.truncated = meta
  let serialized = JSON.stringify(rootObj, null, 2)

  for (let i = 0; i < MAX_ITERATIONS; i++) {
    const cur = Buffer.byteLength(serialized)
    if (cur <= MAX_RESPONSE_BYTES) break
    const fields = collectStringFields(rootObj, 'truncated')
    const largest = pickStringField(fields)
    const arrays = collectArrays(rootObj, 'truncated')
    const widest = arrays.length > 0 ? [...arrays].sort((a, b) => b.size - a.size)[0] : undefined
    const deficit = cur - MAX_RESPONSE_BYTES

    if (largest && largest.size >= 64 && deficit <= largest.size * 4) {
      const target = Math.max(0, largest.size - deficit - SLACK_BYTES)
      setStringField(rootObj, largest.path, target > FIELD_SUFFIX.length ? byteSlice(largest.value, target) + FIELD_SUFFIX : FIELD_SUFFIX)
    } else if (widest && widest.arr.length > 1) {
      const keep = Math.max(1, Math.floor(widest.arr.length * (MAX_RESPONSE_BYTES / cur)))
      widest.arr.length = keep
    } else if (largest) {
      if (largest.size <= FIELD_SUFFIX.length) break
      setStringField(rootObj, largest.path, FIELD_SUFFIX)
    } else {
      const biggestKey = largestKeyBySize(rootObj, 'truncated')
      if (!biggestKey) break
      delete rootObj[biggestKey]
    }
    serialized = JSON.stringify(rootObj, null, 2)
  }

  // 回填 truncated.returned_size（固定点迭代收敛）。
  let s = JSON.stringify(rootObj, null, 2)
  for (let i = 0; i < 4 && meta.returned_size !== Buffer.byteLength(s); i++) {
    meta.returned_size = Buffer.byteLength(s)
    s = JSON.stringify(rootObj, null, 2)
  }
  if (Buffer.byteLength(s) > MAX_RESPONSE_BYTES) {
    const fb = { error: 'response too large to truncate within guard budget', truncated: meta }
    const fbText = JSON.stringify(fb)
    meta.returned_size = Buffer.byteLength(fbText)
    return fbText
  }
  return s
}

/** 选择要截断的字符串字段：默认最大的；content/text 类字段达到最大字段
 *  一半以上大小时优先（截内容比截 ID/元数据语义损失小）。 */
function pickStringField(fields) {
  if (fields.length === 0) return undefined
  const sorted = [...fields].sort((a, b) => b.size - a.size)
  const largest = sorted[0]
  const key = (f) => f.path[f.path.length - 1] ?? ''
  const contentLike = sorted.find((f) => CONTENT_KEYS.has(key(f)) && f.size * 2 >= largest.size)
  return contentLike ?? largest
}

/** 递归收集对象内所有字符串字段（跳过 skipKey 子树，即 truncated 元数据）。 */
function collectStringFields(node, skipKey, prefix = [], out = []) {
  if (typeof node === 'string') {
    out.push({ path: prefix, value: node, size: Buffer.byteLength(node) })
    return out
  }
  if (Array.isArray(node)) {
    node.forEach((v, i) => collectStringFields(v, skipKey, [...prefix, String(i)], out))
    return out
  }
  if (isObject(node)) {
    for (const [k, v] of Object.entries(node)) {
      if (k === skipKey) continue
      collectStringFields(v, skipKey, [...prefix, k], out)
    }
  }
  return out
}

/** 递归收集对象内所有数组（跳过 truncated 元数据），size=序列化字节数。 */
function collectArrays(node, skipKey, prefix = [], out = []) {
  if (Array.isArray(node)) {
    out.push({ path: prefix, arr: node, size: Buffer.byteLength(JSON.stringify(node)) })
    node.forEach((v, i) => collectArrays(v, skipKey, [...prefix, String(i)], out))
    return out
  }
  if (isObject(node)) {
    for (const [k, v] of Object.entries(node)) {
      if (k === skipKey) continue
      collectArrays(v, skipKey, [...prefix, k], out)
    }
  }
  return out
}

/** 按路径改写一个字符串字段的值（路径在收集后、本轮结构未变前有效）。 */
function setStringField(root, path, value) {
  let node = root
  for (const key of path.slice(0, -1)) {
    node = node[key]
  }
  node[path[path.length - 1]] = value
}

/** 根对象里序列化字节数最大的子键（跳过 truncated 元数据）。 */
function largestKeyBySize(obj, skipKey) {
  let best
  let bestSize = -1
  for (const [k, v] of Object.entries(obj)) {
    if (k === skipKey) continue
    const size = Buffer.byteLength(JSON.stringify(v))
    if (size > bestSize) {
      bestSize = size
      best = k
    }
  }
  return best
}

// ---------------------------------------------------------------------------
// plain text truncate
// ---------------------------------------------------------------------------

/** 纯文本截断：UTF-8 边界安全截断 + 追加标记，总长 ≤ MAX_RESPONSE_BYTES。 */
function truncatePlainText(text, original) {
  const fmt = (returned) => `\n... [truncated original=${original} returned=${returned}]`
  let returned = MAX_RESPONSE_BYTES
  for (let i = 0; i < 8; i++) {
    const marker = fmt(returned)
    const budget = Math.max(0, MAX_RESPONSE_BYTES - Buffer.byteLength(marker))
    const body = byteSlice(text, budget)
    const next = Buffer.byteLength(body) + Buffer.byteLength(marker)
    if (next === returned) break
    returned = next
  }
  const marker = fmt(returned)
  return byteSlice(text, Math.max(0, MAX_RESPONSE_BYTES - Buffer.byteLength(marker))) + marker
}

// ---------------------------------------------------------------------------
// shared helpers
// ---------------------------------------------------------------------------

/** 按字节预算截断字符串，不切断 UTF-8 多字节字符。 */
function byteSlice(text, maxBytes) {
  if (maxBytes <= 0) return ''
  const buf = Buffer.from(text, 'utf8')
  if (buf.byteLength <= maxBytes) return text
  let s = buf.subarray(0, maxBytes).toString('utf8')
  while (Buffer.byteLength(s) > maxBytes) s = s.slice(0, -1)
  return s
}

function safeParse(text) {
  try {
    return { ok: true, value: JSON.parse(text) }
  } catch {
    return { ok: false }
  }
}

function isObject(v) {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}
