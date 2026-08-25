#!/usr/bin/env node
/**
 * dsh-chatgpt-connector MCP 代理（单机升级能力层）。
 *
 * 拓扑：ChatGPT ── Tunnel ──> tunnel-client ──> mcp-proxy (3461/mcp) ──> helm daemon (3457) ──> DSH web (3080)
 *
 * 在 tunnel 与 daemon 之间加一层轻量代理，为单机链路提供三项升级能力：
 *  - 内容瘦身：sessions_get 默认返回结构化摘要（lib/summary.mjs）
 *  - 插队机制：sessions_prompt mode=steer 经 DSH 宿主 API 注入运行中回合（lib/steer.mjs）
 *  - 响应守卫：所有 tools/call 响应过 MAX_RESPONSE_BYTES 截断（lib/guard.mjs）
 *
 * HTTP 面为标准 MCP streamable HTTP 子集：POST /mcp 的 JSON-RPC
 * （initialize / notifications/* / tools/list / tools/call）+ GET /healthz。
 * 零第三方依赖（Node 原生 http/fetch）。
 */

import { createServer } from 'node:http'
import { DaemonClient, DEFAULT_DAEMON_URL } from './lib/daemon.mjs'
import { SessionSummaryService } from './lib/summary.mjs'
import { steerPrompt } from './lib/steer.mjs'
import { applyGuard, MAX_RESPONSE_BYTES } from './lib/guard.mjs'

export const DEFAULT_PORT = 3461
export const DEFAULT_HOST_API_URL = 'http://127.0.0.1:3080'
export const PROXY_VERSION = '0.2.0'

const WRITE_TOOLS = new Set(['sessions_prompt', 'sessions_resume', 'sessions_cancel'])

/** 会话写操作后的摘要缓存失效（写后不读脏缓存）。 */
function invalidateAfter(summaries, name, args) {
  const sid = args?.session_id
  if (!sid) return
  if (name === 'sessions_prompt' || name === 'sessions_resume' || name === 'sessions_cancel') {
    summaries.invalidate(sid)
  }
}

/** 单条 MCP 响应包装：结构化内容 JSON 进 text 块（MCP content 标准）。 */
function text(payload) {
  return { content: [{ type: 'text', text: JSON.stringify(payload) }] }
}

export class McpProxy {
  constructor(opts = {}) {
    this.port = opts.port ?? DEFAULT_PORT
    this.daemonUrl = opts.daemonUrl ?? DEFAULT_DAEMON_URL
    this.hostApiUrl = opts.hostApiUrl ?? DEFAULT_HOST_API_URL
    this.logFn = opts.log ?? ((l) => console.log(`[mcp-proxy] ${l}`))
    this.daemon = opts.daemon ?? new DaemonClient({ url: this.daemonUrl, token: opts.token, log: this.logFn })
    this.summaries = new SessionSummaryService(this.daemon, { cacheDir: opts.cacheDir, log: this.logFn })
    this.steerFetch = opts.steerFetch
    this.server = undefined
  }

  log(line) {
    this.logFn(line)
  }

  /** tools/call 处理：升级能力拦截 + 透传 + 统一守卫。 */
  async handleToolCall(name, args) {
    // ① 内容瘦身：sessions_get 默认摘要（include_messages=true 走完整历史）
    if (name === 'sessions_get') {
      const payload = await this.summaries.getSession(args ?? {})
      return text(payload)
    }
    // ② 插队机制：sessions_prompt mode=steer 经宿主 API 注入（MCP 工具层不透传 mode）
    if (name === 'sessions_prompt' && args?.mode === 'steer') {
      const result = await steerPrompt({
        hostApiUrl: this.hostApiUrl,
        sessionId: args.session_id,
        message: args.message,
        fetchImpl: this.steerFetch,
        log: this.logFn,
      })
      if (result.status === 'steered') this.summaries.invalidate(args.session_id)
      return text(result)
    }
    // ③ 其余：透传 daemon（写操作后摘要失效）
    const result = await this.daemon.callTool(name, args ?? {})
    if (WRITE_TOOLS.has(name)) invalidateAfter(this.summaries, name, args)
    return result
  }

  /** 所有 tools/call 响应统一过 Response Size Guard（兜底防线）。 */
  async callWithGuard(name, args) {
    try {
      const out = await this.handleToolCall(name, args)
      return applyGuard(out, name, this.logFn)
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      this.log(`tool ${name} error: ${msg}`)
      return applyGuard(text({ error: msg }), name, this.logFn)
    }
  }

  /** 启动 HTTP server（POST /mcp + GET /healthz + GET /version）。 */
  listen() {
    this.server = createServer((req, res) => {
      if (req.method === 'GET' && req.url === '/healthz') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ ok: true, daemon: this.daemonUrl, host_api: this.hostApiUrl, version: PROXY_VERSION }))
        return
      }
      if (req.method === 'GET' && req.url === '/version') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ name: 'dsh-chatgpt-connector-mcp-proxy', version: PROXY_VERSION }))
        return
      }
      if (req.method === 'POST' && req.url === '/mcp') {
        let body = ''
        req.on('data', (c) => (body += c))
        req.on('end', () => {
          void (async () => {
            try {
              const call = JSON.parse(body)
              if (call.method === 'initialize') {
                res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': `proxy-${Date.now().toString(36)}` })
                res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'dsh-chatgpt-connector-mcp-proxy', version: PROXY_VERSION } } }))
                return
              }
              if (typeof call.method === 'string' && call.method.startsWith('notifications/')) {
                res.writeHead(202, { 'content-type': 'application/json' })
                res.end()
                return
              }
              if (call.method === 'tools/list') {
                const tools = await this.daemon.listTools()
                res.writeHead(200, { 'content-type': 'application/json' })
                res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { tools } }))
                return
              }
              if (call.method === 'tools/call' && call.params?.name) {
                const out = await this.callWithGuard(call.params.name, call.params.arguments ?? {})
                res.writeHead(200, { 'content-type': 'application/json' })
                res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: out }))
                return
              }
              res.writeHead(400, { 'content-type': 'application/json' })
              res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, error: { code: -32601, message: `method not found: ${call.method}` } }))
            } catch (err) {
              this.log(`mcp request error: ${err instanceof Error ? err.message : String(err)}`)
              res.writeHead(500, { 'content-type': 'application/json' })
              res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32603, message: String(err) } }))
            }
          })()
        })
        return
      }
      res.writeHead(404, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: 'not found' }))
    })
    return new Promise((resolve, reject) => {
      this.server.once('error', reject)
      this.server.listen(this.port, '127.0.0.1', () => {
        this.log(`MCP proxy listening on 127.0.0.1:${this.port}/mcp (daemon=${this.daemonUrl}, host_api=${this.hostApiUrl}, guard=${MAX_RESPONSE_BYTES}B)`)
        resolve()
      })
    })
  }

  close() {
    this.server?.close()
  }
}

// CLI 入口（launchd 常驻）
if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const flag = (name, dflt) => {
    const i = args.indexOf(name)
    return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : dflt
  }
  const proxy = new McpProxy({
    port: Number(flag('--port', String(DEFAULT_PORT))),
    daemonUrl: flag('--daemon-url', DEFAULT_DAEMON_URL),
    hostApiUrl: flag('--host-api-url', DEFAULT_HOST_API_URL),
  })
  proxy.listen().catch((err) => {
    console.error(`[mcp-proxy] failed to start: ${err instanceof Error ? err.message : String(err)}`)
    process.exit(1)
  })
}

export { MAX_RESPONSE_BYTES }
