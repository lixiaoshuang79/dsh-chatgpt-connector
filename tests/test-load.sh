#!/usr/bin/env bash
# test-load.sh — 高负载下 watchdog 不误杀 集成测试
#
# 单台 HTTP 服务器同时服务两个动态端口，行为由状态文件控制：
#   mode=fast   → 立即 200
#   mode=slow   → 延迟 1.5s（>1s 探针超时）
# 模拟：高负载时 web 慢但 MCP 正常 → 不 kill；双端点都慢 → 3 轮后重启。
#
# 用法：bash test-load.sh

set -u
cd "$(dirname "$0")"

TMP=$(mktemp -d /tmp/watchdog-load-test.XXXXXX)
WEB_PORT=0
MCP_PORT=0
export WATCH_WEB_PORT=$WEB_PORT
export WATCH_MCP_PORT=$MCP_PORT
export WATCH_LOG_DIR="$TMP/logs"
export WATCH_PID_FILE="$TMP/watchdog.pid"
export WATCH_HELM_AUTH_FILE="$TMP/watchdog-token"
export WATCH_HELM_RUN_DIR="$TMP/helmrun"
export WATCH_FAIL_THRESHOLD=3
export WATCHDOG_INTERVAL=1
export WATCH_PROBE_TIMEOUT=1
export DSH_HARNESS_DIR="$TMP/harness"
export WATCH_NODE_BIN="$TMP/fake-node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fake-node"
chmod +x "$TMP/fake-node"
mkdir -p "$TMP/logs" "$TMP/helmrun" "$TMP/harness"

PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "  ✓ $name"; else FAIL=$((FAIL+1)); echo "  ✗ $name"; fi }

# 双端口单服务器（动态空闲端口），行为由 TMP/mode-<port> 控制
cat > "$TMP/server.py" << 'PYEOF'
import http.server, sys, time, threading
TMP = sys.argv[1]
probe = http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
p1 = probe.server_address[1]; probe.server_close()
probe = http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)
p2 = probe.server_address[1]; probe.server_close()
with open(f"{TMP}/ports", "w") as f:
    f.write(f"{p1} {p2}\n")
def mode(port):
    try:
        return open(f"{TMP}/mode-{port}").read().strip()
    except Exception:
        return "fast"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        m = mode(self.server.server_address[1])
        if m == "slow":
            time.sleep(1.5)
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self, *a): pass
for port in (p1, p2):
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
while True: time.sleep(5)
PYEOF
python3 "$TMP/server.py" "$TMP" &
SRV=$!
# 等 python 分配端口（最多 5s）
waited=0
while [ ! -f "$TMP/ports" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
read -r WEB_TEST_PORT MCP_TEST_PORT < "$TMP/ports"
WEB_PORT=$WEB_TEST_PORT
MCP_PORT=$MCP_TEST_PORT
export WATCH_WEB_PORT=$WEB_TEST_PORT
export WATCH_MCP_PORT=$MCP_TEST_PORT
sleep 1

# source 脚本拿函数
sed 's/^while true; do/while false; do/' "$(cd .. && pwd)/scripts/dsh-web-watchdog.sh" > "$TMP/extracted.sh"
source "$TMP/extracted.sh"
port_pid() { lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1; }
is_dsh() { return 0; }
RESTART_COUNT=0
restart_web() { RESTART_COUNT=$((RESTART_COUNT+1)); }
launch_web() { RESTART_COUNT=$((RESTART_COUNT+1)); }

# 一轮检查（脚本主循环逻辑副本）
tick() {
  ui_ok=0; mcp_ok=0
  port_pid "$WEB_PORT" >/dev/null && is_dsh && web_healthy && ui_ok=1
  mcp_healthy && mcp_ok=1
  [ "$ui_ok" = "1" ] && ui_fail=0 || ui_fail=$((ui_fail+1))
  [ "$mcp_ok" = "1" ] && mcp_fail=0 || mcp_fail=$((mcp_fail+1))
  if [ "$ui_fail" -ge "$FAIL_THRESHOLD" ] && [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0; mcp_fail=0; restart_web
  elif [ "$ui_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0
  elif [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0; mcp_fail=0; restart_web
  fi
}

echo "== 测试 1：web 慢 + MCP 快（高负载场景）→ 探针判 web 不健康 =="
echo slow > "$TMP/mode-$WEB_TEST_PORT"
echo fast > "$TMP/mode-$MCP_TEST_PORT"
web_healthy && WH=1 || WH=0
check "慢 web 端点被判不健康 (WH=0)" test "$WH" = "0"
mcp_healthy && MH=1 || MH=0
check "快 MCP 端点判健康 (MH=1)" test "$MH" = "1"

echo "== 测试 2：高负载 5 轮（web 慢 + MCP 快）→ 不重启 =="
ui_fail=0; mcp_fail=0; RESTART_COUNT=0
for i in 1 2 3 4 5; do tick; done
check "5 轮后 RESTART_COUNT=0" test "$RESTART_COUNT" = "0"
check "mcp_fail=0" test "$mcp_fail" = "0"

echo "== 测试 3：双端点都慢（真死锁）→ 3 轮后重启 =="
echo slow > "$TMP/mode-$MCP_TEST_PORT"
ui_fail=0; mcp_fail=0; RESTART_COUNT=0
for i in 1 2 3; do tick; done
check "3 轮双慢触发重启 (RESTART_COUNT=1)" test "$RESTART_COUNT" = "1"

echo "== 测试 4：恢复后不再重启 =="
echo fast > "$TMP/mode-$WEB_TEST_PORT"
echo fast > "$TMP/mode-$MCP_TEST_PORT"
for i in 1 2; do tick; done
check "恢复后 RESTART_COUNT 不变 (仍=1)" test "$RESTART_COUNT" = "1"

kill $SRV 2>/dev/null
rm -rf "$TMP"
echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
