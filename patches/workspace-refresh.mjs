#!/usr/bin/env node
/**
 * workspace-refresh patch —— 修复 daemon ProjectRegistry 启动快照缺陷
 *
 * 背景（2026-08-26 实测定位）：agent-chatgpt-helm daemon 的 code_use_workspace
 * 走 projects registry（ProjectRegistry）校验，而该 registry 只在
 * onRegister（adapter 建立连接）时从 adapter.listWorkspaces() 同步一次、
 * onDisconnect 时整体移除——**之后在 DSH 侧新注册的 workspace 永远不会
 * 进入它**。症状：workspaces_list（动态读 adapter）能列出新工作区，但
 * code_use_workspace 仍抛 `project is not registered/authorized`。
 * ChatGPT 在任何新项目上都无法启用 Serena 代码智能，必须先重启 web。
 *
 * 修复：code_use_workspace 的 projects.resolve 失败时，回退到 adapter 实时
 * listWorkspaces()（动态反映 DSH workspaceRegistry），匹配到即激活并顺手
 * registerWorkspace 补进 ProjectRegistry——此后同一路径直接 resolve 成功，
 * 以后新增工作区无需重启即对 code_* 工具生效。
 *
 * 幂等：检测到新逻辑已存在则退出 0；应用前自动备份 .bak-workspacerefresh-<ts>。
 * 应用后需重启 DSH web（launchctl kickstart -k gui/$(id -u)/com.dsh-connector.dsh-web-watchdog
 * 或由 watchdog 兜底）才生效。插件重装/升级后重跑本脚本即可。
 *
 * 用法：node patches/workspace-refresh.mjs [--plugin <lib/index.js 路径>]
 */

import { readFileSync, writeFileSync, copyFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'

const HOME = process.env.HOME ?? '.'
const argOf = (flag) => {
  const i = process.argv.indexOf(flag)
  return i > -1 ? process.argv[i + 1] : undefined
}
const target =
  argOf('--plugin') ?? join(HOME, '.dsh/profiles/web/node_modules/@beforewave/agent-chatgpt-helm/lib/index.js')

// 原实现：projects registry 一次性校验，失败即抛（新注册 workspace 永远不可达）
const OLD =
  'if(o.projects)u=o.projects.resolve(l);else{let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw new Error(`workspace is not registered/authorized: ${l}`);if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0]}'

// 新实现：resolve 失败 → 回退 adapter 实时列表（动态反映 DSH workspaceRegistry），
// 匹配到即补注册进 ProjectRegistry（sources=adapter id），后续直接命中。
const NEW =
  'if(o.projects){try{u=o.projects.resolve(l)}catch(z){let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw z;if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0];o.projects.registerWorkspace(u,Dt(o,i).id)}}else{let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw new Error(`workspace is not registered/authorized: ${l}`);if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0]}'

const IDEMPOTENT_MARK = 'o.projects.registerWorkspace(u,Dt(o,i).id)'

if (!existsSync(target)) {
  console.error(`✗ 目标不存在: ${target}\n请确认插件已安装（--plugin 可指定路径）`)
  process.exit(1)
}
const src = readFileSync(target, 'utf8')

if (src.includes(IDEMPOTENT_MARK)) {
  console.log('✓ workspace-refresh 已应用（跳过）')
  process.exit(0)
}
if (!src.includes(OLD)) {
  console.error('✗ 未找到原实现片段，插件版本可能已变化（无法自动打补丁）')
  process.exit(1)
}

const ts = new Date().toISOString().replace(/[:.]/g, '-')
const bak = `${target}.bak-workspacerefresh-${ts}`
copyFileSync(target, bak)
writeFileSync(target, src.replace(OLD, NEW))

try {
  execFileSync(process.execPath, ['--check', target], { stdio: 'pipe' })
} catch (err) {
  // 语法校验失败 → 回滚
  copyFileSync(bak, target)
  console.error('✗ 补丁后语法校验失败，已回滚：', String(err.stderr ?? err).slice(0, 300))
  process.exit(1)
}
console.log(`✓ workspace-refresh 已应用（备份: ${bak}）`)
console.log('  重启 DSH web 后生效；新增/删除工作区不再需要重启，code_use_workspace 实时可用。')