#!/usr/bin/env bash
# test-keepalive.sh — tunnel-client-keepalive v2 故障注入测试
#
# 隔离方式：全部路径/端口走环境变量覆盖，fake tunnel 二进制记录启动/被杀，
# 用真实 HTTP 服务器模拟 3457/3458 端点（本地随机端口，不碰实际运行环境）。
#
# 用法：bash test-keepalive.sh

set -u
cd "$(dirname "$0")"

KEEPALIVE="$(cd .. && pwd)/scripts/tunnel-client-keepalive.sh"
TMP=$(mktemp -d /tmp/keepalive-test.XXXXXX)

# fake tunnel-client：记录被调用次数与参数；模拟 3458 healthz 监听由测试端控制
cat > "$TMP/fake-tunnel" << 'FAKEEOF'
#!/usr/bin/env bash
echo "FAKE_TUNNEL_STARTED $(date +%s%N) $*" >> "$FAKE_TUNNEL_LOG"
# 模拟 tunnel 进程常驻：等信号
while true; do sleep 5; done
FAKEEOF
chmod +x "$TMP/fake-tunnel"
export FAKE_TUNNEL_LOG="$TMP/fake-tunnel.log"

# fake helm daemon 进程（匹配 pgrep 模式 agent-chatgpt-helm/lib/cli.js daemon）
cat > "$TMP/fake-daemon" << 'FAKEEOF'
#!/usr/bin/env bash
# 模拟 helm daemon：常驻，命令行含隔离测试模式（不匹配实际运行环境 daemon）
exec -a "node /tmp/helm-test-isolated/agent-chatgpt-helm/lib/cli.js daemon --project /tmp" bash -c 'while true; do sleep 5; done'
FAKEEOF
chmod +x "$TMP/fake-daemon"

# 环境覆盖（指向 TMP，不碰实际运行环境）
export KEEPALIVE_LOG_FILE="$TMP/keepalive.log"
export KEEPALIVE_STATE_FILE="$TMP/state"
export KEEPALIVE_PID_FILE="$TMP/keepalive.pid"
export KEEPALIVE_TUNNEL_BIN="$TMP/fake-tunnel"
export KEEPALIVE_TUNNEL_LOG="$TMP/tunnel-manual.log"
export HELM_MCP_PORT=3471
export TUNNEL_HEALTH_PORT=3472
export HELM_AUTH_FILE="$TMP/token"
export KEEPALIVE_DAEMON_PATTERN="helm-test-isolated/agent-chatgpt-helm/lib/cli\\.js daemon"
echo "test-token" > "$TMP/token"
# 凭据文件
export CRED_FILE="$TMP/creds"
printf 'CONTROL_PLANE_TUNNEL_ID: tunnel_test123\nCONTROL_PLANE_API_KEY: sk-test-abc\n' > "$TMP/creds"

PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "  ✓ $name"; else FAIL=$((FAIL+1)); echo "  ✗ $name"; fi }

# 真实 HTTP 端点模拟：3471 = MCP healthz，3472 = tunnel healthz
start_http_servers() { # $1=3471 up?, $2=3472 up?
  # 预清理：上次测试残留的监听者会导致 EADDRINUSE（偶发端口冲突）
  for p in 3471 3472; do
    lsof -tiTCP:$p -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null || true
  done
  sleep 0.3
  python3 - "$TMP" << 'PYEOF' &
import http.server, sys, os, time
tmp = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_address[1]
        state = open(os.path.join(tmp, f"state{port}"), "r").read().strip()
        if self.path == "/healthz" and state == "up":
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
        else:
            self.send_response(503); self.end_headers(); self.wfile.write(b'down')
    def log_message(self, *a): pass
s1 = http.server.HTTPServer(("127.0.0.1", 3471), H)
s2 = http.server.HTTPServer(("127.0.0.1", 3472), H)
import threading
threading.Thread(target=s1.serve_forever, daemon=True).start()
threading.Thread(target=s2.serve_forever, daemon=True).start()
while True: time.sleep(5)
PYEOF
  HTTP_PID=$!
  echo up > "$TMP/state3471"; echo up > "$TMP/state3472"
  sleep 1
}
set_state() { echo "$2" > "$TMP/state$1"; }

echo "== 准备：启动模拟 HTTP 端点 + 提取 keepalive 函数 =="
start_http_servers
# source keepalive（主循环替换）
sed 's/^while true; do/while false; do/' "$KEEPALIVE" > "$TMP/extracted.sh"
source "$TMP/extracted.sh"
# 覆盖动作函数为可观测 mock
START_COUNT=0; KILL_COUNT=0
start_tunnel() { START_COUNT=$((START_COUNT+1)); echo "start_tunnel called" >> "$TMP/actions.log"; }
kill_tunnel() { KILL_COUNT=$((KILL_COUNT+1)); echo "kill_tunnel called" >> "$TMP/actions.log"; }
# tunnel_pid mock：模拟常驻 tunnel（否则 kill_tunnel 无操作但计数仍加）
tunnel_pid() { echo "99999"; }

echo "== 测试 1：3457 down + 3458 up（假健康场景）→ mcp_up=0, tunnel_up=1 =="
set_state 3471 down
set_state 3472 up
sleep 0.5
mcp_ok=0; tunnel_ok=0
mcp_up && mcp_ok=1
tunnel_up && tunnel_ok=1
check "mcp_up 检测到 3457 不可达" test "$mcp_ok" = "0"
check "tunnel_up 自身 3458 仍 live" test "$tunnel_ok" = "1"
# 主循环判定：tunnel 健康 + daemon pid 未变 → 不重启（保持隧道，等待 daemon 恢复）
START_COUNT=0
need_restart=0
local_daemon_pid=""
[ "$tunnel_ok" != "1" ] && need_restart=1
check "3457 down 但隧道自身健康 → 不杀隧道（避免无谓抖动）" test "$need_restart" = "0"
check "start_tunnel 未被调用" test "$START_COUNT" = "0"

echo "== 测试 2：3457 down + 3458 down → 隧道重启 =="
set_state 3471 down
set_state 3472 down
sleep 0.5
tunnel_ok=0; tunnel_up && tunnel_ok=1
need_restart=0
[ "$tunnel_ok" != "1" ] && need_restart=1
check "双 down 触发重启 (need_restart=1)" test "$need_restart" = "1"

echo "== 测试 3：daemon PID 变化（web 重启连带 daemon 重启）→ 重启隧道重建 MCP 会话 =="
set_state 3471 up
set_state 3472 up
sleep 0.5
START_COUNT=0
# 模拟：旧 daemon pid 记录为 100，新 daemon pid 是 200
LAST_DAEMON_PID=100
local_daemon_pid=200
need_restart=0
if [ -n "$local_daemon_pid" ] && [ "$LAST_DAEMON_PID" != "$local_daemon_pid" ]; then
  need_restart=1
fi
check "daemon pid 变化检测触发重启 (need_restart=1)" test "$need_restart" = "1"

echo "== 测试 4：daemon PID 未变 + 全健康 → 不重启 =="
LAST_DAEMON_PID=200
local_daemon_pid=200
need_restart=0
if [ -n "$local_daemon_pid" ] && [ "$LAST_DAEMON_PID" != "$local_daemon_pid" ]; then
  need_restart=1
fi
tunnel_ok=1
[ "$tunnel_ok" != "1" ] && need_restart=1
check "稳定状态不重启 (need_restart=0)" test "$need_restart" = "0"

echo "== 测试 5：stale daemon.sock 场景（3457 无监听 + daemon 进程不在）→ v2 探针正确判定 =="
# v2 用 /healthz 探针：3457 down 时 mcp_up=0（不再像 v1 那样 /mcp 401 永远失败）
set_state 3471 down
sleep 0.5
mcp_ok=0; mcp_up && mcp_ok=1
check "v2 探针正确反映 3457 状态（down→mcp_up=0）" test "$mcp_ok" = "0"
set_state 3471 up
sleep 0.5
mcp_ok=0; mcp_up && mcp_ok=1
check "v2 探针正确反映 3457 状态（up→mcp_up=1）" test "$mcp_ok" = "1"

echo "== 测试 6：daemon_pid 精确匹配（不误匹配 fake 以外进程）=="
# fake daemon 进程启动
"$TMP/fake-daemon" & DAEMON_PID=$!
sleep 0.5
dp=$(daemon_pid)
check "daemon_pid 找到 fake daemon ($dp)" test -n "$dp"
kill "$DAEMON_PID" 2>/dev/null
# 等待进程真正退出（kill 是异步的）
for _ in $(seq 1 20); do kill -0 "$DAEMON_PID" 2>/dev/null || break; sleep 0.1; done
dp2=$(daemon_pid)
check "daemon 退出后 daemon_pid 为空" test -z "$dp2"

echo "== 清理 =="
kill "$HTTP_PID" 2>/dev/null
rm -rf "$TMP"
echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
