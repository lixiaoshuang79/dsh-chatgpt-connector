/**
 * Model declaration gate unit tests：声明式模型门禁的纯函数校验。
 * 通过/拒绝/缺声明三态 + 拒绝文本可解析性 + 门禁工具集。
 * 规则与 dsh-helm hub（packages/hub/tests/model-gate.test.ts）一致。
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { checkModelDeclaration, rejectionText, REQUIRED_MODEL, MODEL_GATED_TOOLS } from '../mcp-proxy/lib/model-gate.mjs'

test('allows gpt-5-6-thinking in its canonical form', () => {
  assert.equal(checkModelDeclaration('[model-check] 当前模型是 gpt-5-6-thinking').ok, true)
})

test('allows case/delimiter variants of GPT-5.6 Thinking', () => {
  for (const text of [
    '[model-check] 当前模型是 GPT-5.6 Thinking',
    'chatgpt 当前模型为 gpt-5.6-thinking, 开始执行',
    '我用的是 GPT 5 6 thinking',
    'model: gpt5.6thinking',
  ]) {
    assert.equal(checkModelDeclaration(text).ok, true, text)
  }
})

test('allows GPT-5.6 Sol (case/delimiter variants)', () => {
  for (const text of [
    '[model-check] 当前模型是 gpt-5-6-sol',
    '[model-check] 当前模型是 GPT-5.6 Sol',
    'model: gpt5.6sol',
    '当前模型是 GPT 5 6 Sol，开始执行',
  ]) {
    assert.equal(checkModelDeclaration(text).ok, true, text)
  }
})

test('rejects 5.5-mini declarations with received value', () => {
  assert.deepEqual(checkModelDeclaration('[model-check] 当前模型是 5.5-mini'), {
    ok: false,
    code: 'model_rejected',
    received: '5.5-mini',
  })
})

test('rejects 5.5 mini variants', () => {
  for (const text of ['当前模型 5.5 mini', '我用的是 5.5mini', '[model-check] 5.5-mini']) {
    const r = checkModelDeclaration(text)
    assert.equal(r.ok, false, text)
    assert.equal(r.code, 'model_rejected')
  }
})

test('requires a declaration when the message has none', () => {
  assert.deepEqual(checkModelDeclaration('列出所有 DSH 会话'), { ok: false, code: 'model_declaration_required' })
  assert.equal(checkModelDeclaration('').ok, false)
})

test('rejection text is parseable JSON with required_model', () => {
  const rejected = checkModelDeclaration('5.5-mini')
  const parsed = JSON.parse(rejectionText(rejected))
  assert.equal(parsed.code, 'model_rejected')
  assert.equal(parsed.required_model, REQUIRED_MODEL)
  const missing = checkModelDeclaration('普通指令')
  const parsed2 = JSON.parse(rejectionText(missing))
  assert.equal(parsed2.code, 'model_declaration_required')
})

test('gates exactly the message-injection tools', () => {
  assert.equal(MODEL_GATED_TOOLS.has('sessions_prompt'), true)
  assert.equal(MODEL_GATED_TOOLS.has('sessions_create'), true)
  assert.equal(MODEL_GATED_TOOLS.has('sessions_list'), false)
  assert.equal(MODEL_GATED_TOOLS.has('sessions_get'), false)
})
