#!/usr/bin/env bash
# verify.sh — dsh-chatgpt-connector 部署验证
#
# 检查 4 层健康：
#   1. DSH web UI (3080)
#   2. helm daemon MCP (3457 /healthz)
#   3. tunnel-client 隧道 (3458 /healthz)
#   4. supervisor_health MCP 调用（含 19 个工具清单）
#
# 用法：./verify.sh
# 依赖：curl、lsof；MCP 调用需要 ~/.agent-chatgpt-helm/token（daemon 自动生成）

set -u
TOKEN_FILE="$HOME/.agent-chatgpt-helm/token"
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || echo "")

PASS=0; FAIL=0
check() { # name, condition
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "  ✓ $name"; else FAIL=$((FAIL+1)); echo "  ✗ $name"; fi
}

echo "==== dsh-chatgpt-connector 验证 ===="

# 1. web UI
check "DSH web UI (3080)" curl -fsS --max-time 3 http://127.0.0.1:3080/ >/dev/null 2>&1

# 2. helm daemon MCP
check "helm daemon MCP (3457 /healthz)" curl -fsS --max-time 3 http://127.0.0.1:3457/healthz >/dev/null 2>&1

# 3. tunnel
check "tunnel-client (3458 /healthz)" curl -fsS --max-time 3 http://127.0.0.1:3458/healthz >/dev/null 2>&1

# 4. supervisor_health（需要 token）
if [ -n "$TOKEN" ]; then
  HEALTH=$(curl -sS --max-time 5 -H "Authorization: Bearer $TOKEN" -H "Accept: application/json, text/event-stream" \
    -X POST http://127.0.0.1:3457/mcp \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"supervisor_health","arguments":{}}}' 2>/dev/null)
  if echo "$HEALTH" | grep -q '"status":"ok"'; then
    PASS=$((PASS+1)); echo "  ✓ supervisor_health 返回 ok"
    echo "$HEALTH" | head -c 500; echo ""
  else
    FAIL=$((FAIL+1)); echo "  ✗ supervisor_health 调用失败（token 过期？daemon 未就绪？）"
    echo "$HEALTH" | head -c 300; echo ""
  fi

  # 5. 工具清单
  TOOLS=$(curl -sS --max-time 5 -H "Authorization: Bearer $TOKEN" -H "Accept: application/json, text/event-stream" \
    -X POST http://127.0.0.1:3457/mcp \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' 2>/dev/null)
  N=$(echo "$TOOLS" | grep -o '"name":"' | wc -l | tr -d ' ')
  if [ "$N" -ge 19 ]; then
    PASS=$((PASS+1)); echo "  ✓ 工具清单 $N 个（≥19）"
  else
    FAIL=$((FAIL+1)); echo "  ✗ 工具清单只有 $N 个（期望 ≥19：7 个 code_* + 12 个 supervisor）"
  fi
else
  warn "~/.agent-chatgpt-helm/token 不存在（daemon 未启动？web 重启后自动生成）"
fi

echo ""
echo "结果: $PASS 通过, $FAIL 失败"
[ "$FAIL" = "0" ] && echo "全部就绪 ✅" || echo "有异常，参考 docs/troubleshooting.md"
exit $([ "$FAIL" = "0" ] && echo 0 || echo 1)
