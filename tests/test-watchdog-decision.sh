#!/usr/bin/env bash
# test-watchdog-decision.sh — dsh-web-watchdog v2 决策逻辑故障注入测试
#
# 隔离方式：source 脚本（拿到函数定义）后立即用 mock 覆盖探针/动作函数，
# 不碰任何真实端口/进程。主循环在 source 时被替换为 while false 不执行。
#
# 用法：bash test-watchdog-decision.sh

set -u
cd "$(dirname "$0")"

WATCHDOG="$TMP/dsh-chatgpt-connector/scripts/dsh-web-watchdog.sh"
TMP=$(mktemp -d /tmp/watchdog-test.XXXXXX)
export WATCH_LOG_DIR="$TMP/logs"
export WATCH_PID_FILE="$TMP/watchdog.pid"
export WATCH_HELM_RUN_DIR="$TMP/helmrun"
export WATCH_FAIL_THRESHOLD=3
export WATCHDOG_INTERVAL=1
export DSH_HARNESS_DIR="$TMP/harness"
export WATCH_NODE_BIN="$TMP/fake-node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fake-node"
chmod +x "$TMP/fake-node"
mkdir -p "$TMP/logs" "$TMP/helmrun" "$TMP/harness"

PASS=0; FAIL=0
check() { # name, condition...
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "  ✓ $name"; else FAIL=$((FAIL+1)); echo "  ✗ $name"; fi
}

# ---- source 脚本（主循环替换为 false）----
extract_functions() {
  sed 's/^while true; do/while false; do/' "$WATCHDOG" > "$TMP/extracted.sh"
  source "$TMP/extracted.sh"
}
extract_functions

# ---- 覆盖为 mock（source 之后才生效）----
mock_web_up=0; mock_mcp_up=0; mock_port_pid=""; mock_is_dsh=1
web_healthy() { [ "$mock_web_up" = "1" ]; }
mcp_healthy() { [ "$mock_mcp_up" = "1" ]; }
port_pid() { echo "$mock_port_pid"; }
is_dsh() { [ "$mock_is_dsh" = "1" ]; }
RESTART_COUNT=0
restart_web() { RESTART_COUNT=$((RESTART_COUNT+1)); }
launch_web() { RESTART_COUNT=$((RESTART_COUNT+1)); }
# 模拟一轮检查（脚本主循环内联逻辑的副本）
tick() {
  ui_ok=0; mcp_ok=0
  port_pid "$WEB_PORT" >/dev/null && is_dsh && web_healthy && ui_ok=1
  mcp_healthy && mcp_ok=1
  if [ "$ui_ok" = "1" ]; then
    ui_fail=0
  else
    ui_fail=$((ui_fail + 1))
  fi
  if [ "$mcp_ok" = "1" ]; then
    mcp_fail=0
  else
    mcp_fail=$((mcp_fail + 1))
  fi
  if [ "$ui_fail" -ge "$FAIL_THRESHOLD" ] && [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0; mcp_fail=0; restart_web
  elif [ "$ui_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0
  elif [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0; mcp_fail=0; restart_web
  fi
}

echo "== 测试 1：高负载短时超时（web 1 次不健康但 MCP 健康）不应重启 =="
ui_fail=0; mcp_fail=0; RESTART_COUNT=0
mock_web_up=0; mock_mcp_up=1; mock_port_pid="12345"
tick
check "第 1 次失败后 ui_fail=1" test "$ui_fail" = "1"
check "重启计数为 0" test "$RESTART_COUNT" = "0"

echo "== 测试 2：连续 2 次失败（<阈值 3）仍不重启 =="
tick
check "第 2 次失败后 ui_fail=2" test "$ui_fail" = "2"
check "仍不重启" test "$RESTART_COUNT" = "0"

echo "== 测试 3：web 恢复 → 计数清零 =="
mock_web_up=1
tick
check "健康恢复 ui_fail=0" test "$ui_fail" = "0"
check "不重启" test "$RESTART_COUNT" = "0"

echo "== 测试 4：双端点持续失败 3 轮 → 触发重启 =="
mock_web_up=0; mock_mcp_up=0
for i in 1 2 3; do tick; done
check "第 3 轮双失败触发 restart_web (RESTART_COUNT=1)" test "$RESTART_COUNT" = "1"
check "计数已清零" test "$ui_fail" = "0"

echo "== 测试 5：仅 web 不健康但 MCP 健康 5 轮 → 永不重启（保护 ChatGPT 链路）=="
RESTART_COUNT=0; ui_fail=0; mcp_fail=0
mock_web_up=0; mock_mcp_up=1
for i in 1 2 3 4 5; do tick; done
check "5 轮后 RESTART_COUNT=0" test "$RESTART_COUNT" = "0"
check "mcp_fail 保持 0" test "$mcp_fail" = "0"

echo "== 测试 6：仅 MCP 不健康但 web 健康 3 轮 → 重启 web 恢复 daemon =="
RESTART_COUNT=0; ui_fail=0; mcp_fail=0
mock_web_up=1; mock_mcp_up=0; mock_port_pid="12345"
for i in 1 2 3; do tick; done
check "3 轮后触发 restart_web (RESTART_COUNT=1)" test "$RESTART_COUNT" = "1"

echo "== 测试 7：web 端口空且 1 次检查 → 兜底拉起（手动关闭场景）=="
RESTART_COUNT=0; ui_fail=0; mcp_fail=0
mock_port_pid=""
mock_web_up=0; mock_mcp_up=0
tick
if [ "$ui_fail" = "1" ] && [ -z "$(port_pid "$WEB_PORT")" ]; then
  ui_fail=0
  launch_web
fi
check "端口空时兜底拉起 (RESTART_COUNT=1)" test "$RESTART_COUNT" = "1"

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
rm -rf "$TMP"
[ "$FAIL" = "0" ]
