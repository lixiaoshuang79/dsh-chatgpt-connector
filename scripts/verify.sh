#!/usr/bin/env bash
# verify.sh — dsh-chatgpt-connector 部署验证
#
# 检查 4 层健康：
#   1. DSH web UI (3080)
#   2. helm daemon MCP (3457 /healthz)
#   3. tunnel-client 隧道 (3458 /healthz)
#   4. supervisor_health + tools/list（MCP Streamable HTTP，需 initialize 握手）
#
# 用法：./verify.sh
# 依赖：curl；MCP 调用需要 ~/.agent-chatgpt-helm/token（daemon 自动生成）

set -u
TOKEN_FILE="$HOME/.agent-chatgpt-helm/token"
TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || echo "")
MCP_URL="http://127.0.0.1:3457/mcp"

PASS=0; FAIL=0; SKIP=0
check() { # name, condition
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "  ✓ $name"; else FAIL=$((FAIL+1)); echo "  ✗ $name"; fi
}

warn() { echo "  ⚠ $*"; }

echo "==== dsh-chatgpt-connector 验证 ===="

# 1. web UI
check "DSH web UI (3080)" curl -fsS --max-time 3 http://127.0.0.1:3080/ >/dev/null 2>&1

# 2. helm daemon MCP
check "helm daemon MCP (3457 /healthz)" curl -fsS --max-time 3 http://127.0.0.1:3457/healthz >/dev/null 2>&1

# 3. tunnel
check "tunnel-client (3458 /healthz)" curl -fsS --max-time 3 http://127.0.0.1:3458/healthz >/dev/null 2>&1

# 4/5. MCP 调用（需要 token + initialize 握手）
if [ -n "$TOKEN" ]; then
  # ---- MCP Streamable HTTP 握手：initialize 拿 mcp-session-id ----
  INIT_HEADERS=$(mktemp)
  INIT_BODY=$(curl -sS --max-time 8 -D "$INIT_HEADERS" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -X POST "$MCP_URL" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"dsh-connector-verify","version":"0.1.0"}}}' 2>/dev/null)
  SID=$(grep -i "^mcp-session-id:" "$INIT_HEADERS" 2>/dev/null | tr -d '\r' | awk '{print $2}')
  rm -f "$INIT_HEADERS"

  if [ -z "$SID" ]; then
    FAIL=$((FAIL+1))
    echo "  ✗ MCP initialize 握手失败（未拿到 mcp-session-id）"
    echo "$INIT_BODY" | head -c 300; echo ""
  else
    PASS=$((PASS+1)); echo "  ✓ MCP initialize 握手成功"

    # 4. supervisor_health
    HEALTH=$(curl -sS --max-time 8 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $SID" \
      -X POST "$MCP_URL" \
      -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"supervisor_health","arguments":{}}}' 2>/dev/null)
    if echo "$HEALTH" | grep -q '"status": "ok"\|"status":"ok"'; then
      PASS=$((PASS+1)); echo "  ✓ supervisor_health 返回 ok"
      echo "$HEALTH" | grep -o '"status": *"[a-z]*"' | head -3
    else
      FAIL=$((FAIL+1)); echo "  ✗ supervisor_health 调用失败（token 过期？daemon 未就绪？）"
      echo "$HEALTH" | head -c 300; echo ""
    fi

    # 5. 工具清单
    TOOLS=$(curl -sS --max-time 8 -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $SID" \
      -X POST "$MCP_URL" \
      -d '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' 2>/dev/null)
    N=$(echo "$TOOLS" | grep -o '"name":"' | wc -l | tr -d ' ')
    if [ "$N" -ge 19 ]; then
      PASS=$((PASS+1)); echo "  ✓ 工具清单 $N 个（≥19）"
    else
      FAIL=$((FAIL+1)); echo "  ✗ 工具清单只有 $N 个（期望 ≥19：code_* + supervisor/sessions_*）"
      echo "$TOOLS" | head -c 300; echo ""
    fi
  fi
else
  SKIP=$((SKIP+2))
  FAIL=$((FAIL+2))
  warn "~/.agent-chatgpt-helm/token 不存在——MCP 验证未完成（daemon 未启动？web 重启后自动生成 token 后再跑一次）"
fi

echo ""
if [ "$FAIL" = "0" ]; then
  echo "结果: $PASS 通过, $FAIL 失败${SKIP:+, $SKIP 跳过}"
  echo "全部就绪 ✅"
  exit 0
else
  echo "结果: $PASS 通过, $FAIL 失败${SKIP:+, $SKIP 跳过}"
  echo "有异常，参考 docs/troubleshooting.md"
  exit 1
fi
