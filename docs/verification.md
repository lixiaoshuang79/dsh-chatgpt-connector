# 验证清单

部署完成后按顺序检查。核心：**三层端口全绿 + supervisor_health ok + 工具清单 ≥19**。

## 快速验证

```bash
./scripts/verify.sh
```

输出期望：

```
==== dsh-chatgpt-connector 验证 ====
  ✓ DSH web UI (3080)
  ✓ helm daemon MCP (3457 /healthz)
  ✓ mcp-proxy (3461 /healthz)
  ✓ tunnel-client (3458 /healthz)
  ✓ supervisor_health 返回 ok
  ✓ 工具清单 19 个（≥19）
结果: 6 通过, 0 失败
```

## 手动验证

```bash
# 端口监听
lsof -nP -iTCP:3080 -sTCP:LISTEN   # web
lsof -nP -iTCP:3457 -sTCP:LISTEN   # helm daemon
lsof -nP -iTCP:3458 -sTCP:LISTEN   # tunnel-client
lsof -nP -iTCP:3461 -sTCP:LISTEN   # mcp-proxy（升级能力层）

# 健康端点（3457/3458 的 /healthz 免认证）
curl -s http://127.0.0.1:3457/healthz   # {"status":"ok"}
curl -s http://127.0.0.1:3458/healthz   # ok
curl -s http://127.0.0.1:3461/healthz   # {"ok":true,...}（mcp-proxy）

# supervisor_health（需要 token）
TOKEN=$(cat ~/.agent-chatgpt-helm/token)
curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/json, text/event-stream" \
  -X POST http://127.0.0.1:3457/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"supervisor_health","arguments":{}}}'
# 期望 status:"ok"，tunnel.running:true（或 managed:false——daemon 不自管隧道），adapters 里 dsh 健康
```

## 19 个 MCP 工具

| 类别 | 工具 | 说明 |
|---|---|---|
| 工作区激活 | `code_use_workspace` | 激活代码智能工作区（必须先调用，否则 code_* 报 workspace_required） |
| Serena 代码智能（只读） | `code_read_file` `code_list_dir` `code_find_file` `code_search_for_pattern` `code_get_symbols_overview` `code_find_symbol` `code_find_referencing_symbols` | 当前激活工作区内的只读代码查询 |
| 项目管理 | `projects_list` | 已注册项目列表 |
| 健康 | `supervisor_health` | supervisor/Serena/tunnel/adapters 状态 |
| 代理 | `agents_list` `workspaces_list` | 原生 DSH 代理与授权工作区 |
| 会话 | `sessions_create` `sessions_list` `sessions_get` `sessions_resume` `sessions_prompt` `sessions_wait` `sessions_cancel` | 创建/管理 DSH 原生会话（可在 3080 接管） |

## 进程级验证

```bash
# daemon（web 的子进程）
pgrep -f 'agent-chatgpt-helm/lib/cli\.js daemon'
# tunnel（keepalive 拉起，含 3458 参数）
pgrep -f 'tunnel-client run'
# 守护
launchctl list | grep -E 'dsh-web-watchdog|tunnel-client-keepalive'
```

## 端到端（ChatGPT 侧）

1. 打开 ChatGPT → 选连接器。
2. 提问「列出你能用的工具」或直接给任务（如「读一下 <项目>/README.md 并总结」）。
3. 应看到工具调用卡片与结果。任务会创建 DSH 原生会话，可在本机 3080 的会话列表看到并接管。

升级能力（v0.2.0，mcp-proxy）端到端确认：

```bash
# ① 摘要瘦身：sessions_get 默认返回摘要（无 messages 字段，~KB）——ChatGPT 侧自动生效
curl -s -H 'Content-Type: application/json' -X POST http://127.0.0.1:3461/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sessions_get","arguments":{"session_id":"<会话id>"}}}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["result"]["content"][0]["text"]; print(len(d), "bytes;", "keys:", list(json.loads(d).keys())[:8])'

# ② 插队：mode=steer 立即注入运行中回合（返回 status=steered）
curl -s -H 'Content-Type: application/json' -X POST http://127.0.0.1:3461/mcp \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sessions_prompt","arguments":{"session_id":"<会话id>","message":"先跑 lint 再提交","mode":"steer"}}}'

# ③ 守卫日志：超 50KB 响应截断记录在
tail -50 ~/.dsh/logs/mcp-proxy.out   # [mcp-guard] <tool> original=NNNNN returned=NNNNN truncated
```

## 故障时的信息收集

```bash
# 四个日志
tail -50 ~/.dsh/logs/dsh-web-watchdog.log
tail -50 ~/.dsh/logs/tunnel-client-keepalive.log
tail -50 ~/.dsh/logs/tunnel-client-manual.log
tail -50 ~/.dsh/logs/mcp-proxy.out     # mcp-proxy（摘要缓存/guard 截断/steer 插队）
# 三个端口
lsof -nP -iTCP:3080 -sTCP:LISTEN; lsof -nP -iTCP:3457 -sTCP:LISTEN; lsof -nP -iTCP:3458 -sTCP:LISTEN
# 凭据是否到位（只看键名，勿打印值）
grep -cE '^CONTROL_PLANE_(TUNNEL_ID|API_KEY):' ~/.dsh/.credentials.yaml
```

对照 `docs/troubleshooting.md` 排查。
