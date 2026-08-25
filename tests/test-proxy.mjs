/**
 * mcp-proxy 全链路测试（node:test，零第三方依赖）：
 * mock daemon（3457 语义）+ mock DSH 宿主 API（3080 语义）+ 真实代理 HTTP server。
 * 覆盖：摘要瘦身 / 完整历史超限守卫 / steer 插队 / steer 降级 / 普通工具透传 /
 * 写操作后摘要缓存失效 / daemon 不可达容错。
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { McpProxy } from '../mcp-proxy/server.mjs'

/** 1000 条大 session（~100KB）：最后 20 条窗口内含一条明确 next_action。 */
function bigSession() {
  const messages = []
  for (let i = 0; i < 1000; i++) {
    if (i % 2 === 0) messages.push({ seq: i + 1, time: '2026-08-24T00:00:00Z', role: 'user', text: '收到' })
    else messages.push({ seq: i + 1, time: '2026-08-24T00:00:00Z', role: 'assistant', text: `好的（第 ${i + 1} 轮）` })
  }
  messages[998] = { seq: 999, time: '2026-08-24T00:00:00Z', role: 'user', text: '下一步：先跑 lint 和测试，通过后再提交' }
  return { id: 's-big', title: 'big session', status: 'idle', workspace: 'w-local', updated_at: '2026-08-24T00:00:00Z', messages }
}

/** Mock helm daemon：标准 MCP HTTP + Bearer 校验 + 调用计数。 */
function startMockDaemon(opts = {}) {
  const calls = []
  const server = createServer(async (req, res) => {
    let body = ''
    req.on('data', (c) => (body += c))
    req.on('end', () => {
      if (req.headers.authorization !== `Bearer ${opts.token ?? 'test-token'}`) {
        res.writeHead(401, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32001, message: 'unauthorized' } }))
        return
      }
      const call = JSON.parse(body)
      if (call.method === 'initialize') {
        res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': 'mock-session-1' })
        res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'mock-daemon', version: '0.1.1' } } }))
        return
      }
      if (String(call.method).startsWith('notifications/')) {
        res.writeHead(202, { 'content-type': 'application/json' })
        res.end()
        return
      }
      if (call.method === 'tools/list') {
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { tools: ['sessions_get', 'sessions_prompt', 'sessions_resume', 'sessions_cancel', 'sessions_create', 'code_read_file', 'supervisor_health'].map((n) => ({ name: n, description: `mock ${n}`, inputSchema: {} })) } }))
        return
      }
      if (call.method === 'tools/call') {
        const { name, arguments: args } = call.params ?? {}
        calls.push(name)
        if (name === 'sessions_get') {
          const sid = args?.session_id
          const payload = sid === 's-big' ? bigSession() : { id: sid ?? 's-miss', title: 'small', status: 'idle', workspace: 'w-local', messages: [{ seq: 1, time: 't', role: 'user', text: '你好' }] }
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { content: [{ type: 'text', text: JSON.stringify(payload) }], structuredContent: payload } }))
          return
        }
        if (name === 'sessions_prompt') {
          res.writeHead(200, { 'content-type': 'application/json' })
          res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { ok: true, reply: '[mock-daemon] processed', structuredContent: { ok: true, reply: '[mock-daemon] processed' } } }))
          return
        }
        res.writeHead(200, { 'content-type': 'application/json' })
        res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, result: { content: [{ type: 'text', text: `[mock] ${name}` }], structuredContent: { ok: true, tool: name } } }))
        return
      }
      res.writeHead(400, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ jsonrpc: '2.0', id: call.id, error: { code: -32601, message: `method not found: ${call.method}` } }))
    })
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, calls, port: server.address().port, close: () => server.close() }))
  })
}

/** Mock DSH 宿主 API（3080 语义）：session.list + session.prompt。 */
function startMockHostApi(opts = {}) {
  const calls = []
  const server = createServer(async (req, res) => {
    let body = ''
    req.on('data', (c) => (body += c))
    req.on('end', () => {
      const call = JSON.parse(body)
      calls.push(call.method)
      if (opts.fail) {
        res.writeHead(500)
        res.end()
        return
      }
      let value
      if (call.method === 'session.list') value = { items: opts.running ? [{ sessionId: 's-run', running: true }] : [] }
      else if (call.method === 'session.prompt') value = { accepted: true }
      else value = {}
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ type: 'server-response', result: { ok: true, value } }))
    })
  })
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, calls, port: server.address().port, close: () => server.close() }))
  })
}

async function startProxy(opts = {}) {
  const proxy = new McpProxy({ port: 0, daemonUrl: opts.daemonUrl, hostApiUrl: opts.hostApiUrl, token: 'test-token', cacheDir: mkdtempSync(join(tmpdir(), 'mcp-proxy-test-')) })
  await proxy.listen()
  const base = `http://127.0.0.1:${proxy.server.address().port}`
  const rpc = async (body) => {
    const res = await fetch(`${base}/mcp`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
    return { status: res.status, json: await res.json() }
  }
  return { proxy, base, rpc, close: () => proxy.close() }
}

test('MCP proxy：摘要瘦身（sessions_get 默认返回摘要，无 messages，current_goal 取窗口行动指令）', async () => {
  const daemon = await startMockDaemon()
  const host = await startMockHostApi()
  const p = await startProxy({ daemonUrl: `http://127.0.0.1:${daemon.port}/mcp`, hostApiUrl: `http://127.0.0.1:${host.port}` })
  try {
    await p.rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 't', version: '1' } } })
    const res = await p.rpc({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'sessions_get', arguments: { session_id: 's-big' } } })
    assert.equal(res.status, 200)
    const result = res.json.result
    assert.equal(result.isError, undefined)
    const summary = JSON.parse(result.content[0].text)
    assert.equal('messages' in summary, false)
    assert.equal(summary.current_goal, '下一步：先跑 lint 和测试，通过后再提交')
    assert.equal(summary.current_goal_seq, 999)
    assert.equal(summary.history_ref.reachable_max_messages, 100)
    assert.ok(Buffer.byteLength(result.content[0].text) < 2_000, '摘要应 <2KB')
  } finally {
    p.close(); host.close(); daemon.close()
  }
})

test('MCP proxy：响应守卫（完整历史 ~100KB 截断，JSON 合法且 ≤50KB，带 truncated 元数据）', async () => {
  const daemon = await startMockDaemon()
  const host = await startMockHostApi()
  const p = await startProxy({ daemonUrl: `http://127.0.0.1:${daemon.port}/mcp`, hostApiUrl: `http://127.0.0.1:${host.port}` })
  try {
    await p.rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
    const res = await p.rpc({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'sessions_get', arguments: { session_id: 's-big', include_messages: true } } })
    const text = res.json.result.content[0].text
    const { MAX_RESPONSE_BYTES } = await import('../mcp-proxy/lib/guard.mjs')
    assert.ok(Buffer.byteLength(text) <= MAX_RESPONSE_BYTES + 64)
    const parsed = JSON.parse(text) // 截断后必须是合法 JSON（connector 硬依赖）
    const truncated = parsed.truncated
    assert.ok(truncated, '应带 truncated 元数据')
    assert.ok(truncated.original_size > MAX_RESPONSE_BYTES)
    assert.ok(truncated.returned_size <= MAX_RESPONSE_BYTES)
  } finally {
    p.close(); host.close(); daemon.close()
  }
})

test('MCP proxy：插队（mode=steer 经宿主 API 注入，session_was_running=true，不落 daemon）', async () => {
  const daemon = await startMockDaemon()
  const host = await startMockHostApi({ running: true })
  const p = await startProxy({ daemonUrl: `http://127.0.0.1:${daemon.port}/mcp`, hostApiUrl: `http://127.0.0.1:${host.port}` })
  try {
    await p.rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
    const res = await p.rpc({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'sessions_prompt', arguments: { session_id: 's-run', message: '先跑 lint 再提交', mode: 'steer' } } })
    const out = JSON.parse(res.json.result.content[0].text)
    assert.equal(out.status, 'steered')
    assert.equal(out.session_was_running, true)
    assert.equal(out.accepted, true)
    assert.deepEqual(host.calls, ['session.list', 'session.prompt'])
    assert.equal(daemon.calls.includes('sessions_prompt'), false, 'steer 不落 daemon')
  } finally {
    p.close(); host.close(); daemon.close()
  }
})

test('MCP proxy：插队降级（宿主 API 不可达 → unavailable，不崩代理，queue 照常）', async () => {
  const daemon = await startMockDaemon()
  const host = await startMockHostApi({ fail: true })
  const p = await startProxy({ daemonUrl: `http://127.0.0.1:${daemon.port}/mcp`, hostApiUrl: `http://127.0.0.1:${host.port}` })
  try {
    await p.rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
    const steer = await p.rpc({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'sessions_prompt', arguments: { session_id: 's-run', message: '先跑 lint', mode: 'steer' } } })
    const out = JSON.parse(steer.json.result.content[0].text)
    assert.equal(out.status, 'unavailable')
    // queue 路径（无 mode）照常走 daemon
    const queued = await p.rpc({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'sessions_prompt', arguments: { session_id: 's-run', message: '继续' } } })
    assert.ok(String(queued.json.result.content[0].text).length > 0)
    assert.ok(daemon.calls.includes('sessions_prompt'))
  } finally {
    p.close(); host.close(); daemon.close()
  }
})

test('MCP proxy：普通工具透传不变形 + 写操作后摘要缓存失效（再取摘要时 daemon 重新被调）', async () => {
  const daemon = await startMockDaemon()
  const host = await startMockHostApi()
  const p = await startProxy({ daemonUrl: `http://127.0.0.1:${daemon.port}/mcp`, hostApiUrl: `http://127.0.0.1:${host.port}` })
  try {
    await p.rpc({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} })
    // 普通工具透传
    const read = await p.rpc({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'code_read_file', arguments: { path: '/tmp/a.ts' } } })
    assert.ok(String(read.json.result.content[0].text).includes('[mock] code_read_file'))
    // 第一次摘要（daemon 调用 1 次）
    const before = daemon.calls.filter((c) => c === 'sessions_get').length
    await p.rpc({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'sessions_get', arguments: { session_id: 's-big' } } })
    await p.rpc({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'sessions_get', arguments: { session_id: 's-big' } } })
    assert.equal(daemon.calls.filter((c) => c === 'sessions_get').length, before + 1, '缓存命中：第二次不调 daemon')
    // 写操作（sessions_prompt queue）→ 摘要失效 → 再取重建
    await p.rpc({ jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'sessions_prompt', arguments: { session_id: 's-big', message: '继续' } } })
    await p.rpc({ jsonrpc: '2.0', id: 6, method: 'tools/call', params: { name: 'sessions_get', arguments: { session_id: 's-big' } } })
    assert.equal(daemon.calls.filter((c) => c === 'sessions_get').length, before + 2, '写操作后摘要重建')
  } finally {
    p.close(); host.close(); daemon.close()
  }
})

test('MCP proxy：daemon 不可达 → 结构化错误响应（不崩 server），/healthz 存活', async () => {
  const host = await startMockHostApi()
  const p = await startProxy({ daemonUrl: 'http://127.0.0.1:1/mcp', hostApiUrl: `http://127.0.0.1:${host.port}` })
  try {
    const health = await fetch(`${p.base}/healthz`)
    assert.equal(health.status, 200)
    const res = await p.rpc({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'sessions_get', arguments: { session_id: 's-x' } } })
    assert.equal(res.status, 200)
    const payload = JSON.parse(res.json.result.content[0].text)
    assert.ok(String(payload.error ?? '').includes('unreachable') || String(payload.error ?? '').includes('failed'), `应返回错误：${JSON.stringify(payload)}`)
  } finally {
    p.close(); host.close()
  }
})