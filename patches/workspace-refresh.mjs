#!/usr/bin/env node
/**
 * workspace-refresh patch v2 —— code_use_workspace 全开放（用户授权所有工作区）
 *
 * 背景（2026-08-26 实测定位）：agent-chatgpt-helm daemon 的 code_use_workspace
 * 走 projects registry（ProjectRegistry）校验，该 registry 只在 onRegister
 * （adapter 建立连接）时同步一次 adapter.listWorkspaces()、断开时整体移除。
 *
 * v1：projects.resolve 失败 → 回退 adapter 实时 listWorkspaces（动态反映 DSH
 * workspaceRegistry），匹配即补注册。解决了"新注册工作区不可见"，但路径仍须
 * 预先注册到 DSH workspaceRegistry。
 *
 * v2（本版，用户 2026-08-26 授权"开放所有工作区权限"）：resolve 失败且实时
 * 列表也匹配不到时，**直接把传入路径注册并激活**——任意绝对路径都能启用
 * Serena 代码智能，不再要求预先注册。敏感目录可读风险由授权人承担。
 *
 * 幂等：v2 标记存在则退出 0；兼容已打 v1 / 未打补丁两态（自动替换为 v2）。
 * 应用前自动备份 .bak-workspacerefresh-<ts>；语法校验失败自动回滚。
 * 应用后需重启 DSH web 生效；插件重装/升级后重跑本脚本即可。
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

// 原版（未打补丁）：仅 ProjectRegistry 快照校验，失败即抛
const ORIGINAL =
  'if(o.projects)u=o.projects.resolve(l);else{let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw new Error(`workspace is not registered/authorized: ${l}`);if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0]}'

// v1（上一版）：resolve 失败 → 回退实时列表，匹配即补注册；仍要求预先注册
const V1 =
  'if(o.projects){try{u=o.projects.resolve(l)}catch(z){let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw z;if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0];o.projects.registerWorkspace(u,Dt(o,i).id)}}else{let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw new Error(`workspace is not registered/authorized: ${l}`);if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0]}'

// v2（本版）：resolve 失败 → 实时列表匹配；匹配不到 → 任意路径直接注册激活
const V2 =
  'if(o.projects){try{u=o.projects.resolve(l)}catch(z){let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length){let x={id:l,path:l,title:l.split("/").pop()};u=o.projects.registerWorkspace(x,Dt(o,i).id)}else{if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0];o.projects.registerWorkspace(u,Dt(o,i).id)}}}else{let E=(await Dt(o,i).listWorkspaces()).filter(P=>P.id===l||P.path===l||P.title===l);if(!E.length)throw new Error(`workspace is not registered/authorized: ${l}`);if(E.length>1)throw new Error(`workspace reference is ambiguous; use workspace id or full path: ${l}`);u=E[0]}'

const V2_MARK = 'let x={id:l,path:l,title:l.split("/").pop()}'

if (!existsSync(target)) {
  console.error(`✗ 目标不存在: ${target}\n请确认插件已安装（--plugin 可指定路径）`)
  process.exit(1)
}
const src = readFileSync(target, 'utf8')

if (src.includes(V2_MARK)) {
  console.log('✓ workspace-refresh v2（全开放）已应用（跳过）')
  process.exit(0)
}
let next = src
if (src.includes(V1)) {
  next = src.replace(V1, V2)
} else if (src.includes(ORIGINAL)) {
  next = src.replace(ORIGINAL, V2)
} else {
  console.error('✗ 未找到 v1/原版实现片段，插件版本可能已变化（无法自动打补丁）')
  process.exit(1)
}

const ts = new Date().toISOString().replace(/[:.]/g, '-')
const bak = `${target}.bak-workspacerefresh-${ts}`
copyFileSync(target, bak)
writeFileSync(target, next)

try {
  execFileSync(process.execPath, ['--check', target], { stdio: 'pipe' })
} catch (err) {
  copyFileSync(bak, target)
  console.error('✗ 补丁后语法校验失败，已回滚：', String(err.stderr ?? err).slice(0, 300))
  process.exit(1)
}
console.log(`✓ workspace-refresh v2（全开放）已应用（备份: ${bak}）`)
console.log('  code_use_workspace 现接受任意绝对路径（用户授权全开放），重启 DSH web 后生效。')