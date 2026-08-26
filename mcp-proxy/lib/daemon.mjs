/**
 * MCP client：以标准 MCP（initialize / tools/list / tools/call）连本机 helm
 * daemon `http://127.0.0.1:3457/mcp`（Bearer token），维护 mcp-session-id。
 * 零第三方依赖（Node 原生 fetch）。
 */

import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const DEFAULT_DAEMON_URL = 'http://127.0.0.1:3457/mcp'
/** daemon Bearer token 文件：agent-helm >=0.1.2 新路径优先，旧路径兜底。 */
export const DAEMON_TOKEN_FILES = [
  join(homedir(), '.agent-helm', 'token'),
  join(homedir(), '.agent-chatgpt-helm', 'token'),
]

function readTokenFile() {
  for (const f of DAEMON_TOKEN_FILES) {
    try {
      const t = readFileSync(f, 'utf8').trim()
      if (t) return t
    } catch {
      /* try next */
    }
  }
  return ''
}

export class DaemonClient {
  constructor(opts = {}) {
    this.url = opts.url ?? DEFAULT_DAEMON_URL
    this.token = opts.token ?? readTokenFile()
    this.fetchImpl = opts.fetchImpl ?? ((...args) => fetch(...args))
    this.logFn = opts.log
    this.timeoutMs = opts.timeoutMs ?? 30_000
    this.sessionId = undefined
    this.serverInfo = undefined
    this.nextId = 1
  }

  log(line) {
    this.logFn?.(line)
  }

  async post(body) {
    const headers = { 'content-type': 'application/json', accept: 'application/json, text/event-stream' }
    if (this.token) headers.authorization = `Bearer ${this.token}`
    if (this.sessionId) headers['mcp-session-id'] = this.sessionId
    const ac = new AbortController()
    const timer = setTimeout(() => ac.abort(), this.timeoutMs)
    let res
    try {
      res = await this.fetchImpl(this.url, { method: 'POST', headers, body: JSON.stringify(body), signal: ac.signal })
    } catch (err) {
      throw new Error(`daemon mcp unreachable: ${err instanceof Error ? err.message : String(err)}`)
    } finally {
      clearTimeout(timer)
    }
    if (!res.ok) {
      const err = new Error(`daemon mcp http ${res.status}`)
      err.status = res.status
      throw err
    }
    const sid = res.headers.get('mcp-session-id')
    if (sid) this.sessionId = sid
    const json = await res.json()
    if (json.error) {
      const err = new Error(json.error.message ?? `daemon mcp error ${json.error.code ?? ''}`)
      err.rpc_code = json.error.code
      throw err
    }
    return { body: json, headers: res.headers }
  }

  /** MCP initialize；幂等（session 存活期间不重复握手）。 */
  async connect() {
    if (this.sessionId) return this.serverInfo ?? {}
    const res = await this.post({
      jsonrpc: '2.0',
      id: this.nextId++,
      method: 'initialize',
      params: {
        protocolVersion: '2025-03-26',
        capabilities: {},
        clientInfo: { name: 'dsh-chatgpt-connector-mcp-proxy', version: '0.3.0' },
      },
    })
    this.serverInfo = res.body.result?.serverInfo
    try {
      await this.post({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} })
    } catch {
      /* daemon tolerates missing notification */
    }
    return this.serverInfo ?? {}
  }

  /**
   * 带自动重握手的调用：daemon 重启后旧 mcp-session-id 失效（404 unknown
   * MCP session），此时重置会话、重新 initialize 并重试一次——web 重启后
   * mcp-proxy 无需人工恢复。
   */
  async postResilient(body, retried = false) {
    try {
      return await this.post(body)
    } catch (err) {
      if (!retried && err instanceof Error && err.status === 404) {
        this.log('daemon mcp 404（session 失效，可能 daemon 已重启）— 重新握手并重试')
        this.sessionId = undefined
        await this.connect()
        return await this.postResilient(body, true)
      }
      throw err
    }
  }

  /** 调用一个 MCP 工具；返回 { structuredContent?, content? }。 */
  async callTool(name, args) {
    await this.connect()
    const res = await this.postResilient({
      jsonrpc: '2.0',
      id: this.nextId++,
      method: 'tools/call',
      params: { name, arguments: args ?? {} },
    })
    const result = res.body.result
    if (!result) throw new Error(`daemon mcp tool ${name}: empty result`)
    if (result.isError) {
      const text = result.content?.map((c) => c.text ?? '').join('\n') ?? ''
      throw new Error(`daemon mcp tool ${name} error: ${text.slice(0, 300)}`)
    }
    return result
  }

  /** tools/list 动态发现工具面。 */
  async listTools() {
    await this.connect()
    const res = await this.postResilient({ jsonrpc: '2.0', id: this.nextId++, method: 'tools/list', params: {} })
    return res.body.result?.tools ?? []
  }
}
