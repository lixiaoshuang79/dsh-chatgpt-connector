#!/usr/bin/env bash
# test-stall-detection.sh — watchdog v3 datapath stall detection 独立测试
#
# 覆盖四类场景：
#   A. UI fail + sessions_list ok        → datapath 活，清 stall，不重启
#   B. UI fail + sessions_list fail + active=0 → 连续 2 轮 stall → snapshot + restart
#   C. UI fail + sessions_list fail + active>0 within grace → 保护不重启
#   D. UI fail + sessions_list fail + active>0 beyond grace → snapshot + restart
#
# 隔离方式：source 脚本（主循环替换 while false）后 mock 探针/动作函数，
# mcp_probe_sessions 用状态变量模拟返回，不碰真实 MCP/token/端口。
#
# 用法：bash test-stall-detection.sh

set -u
cd "$(dirname "$0")"

WATCHDOG="$(cd .. && pwd)/scripts/dsh-web-watchdog.sh"
TMP=$(mktemp -d /tmp/watchdog-stall-test.XXXXXX)
export WATCH_LOG_DIR="$TMP/logs"
export WATCH_PID_FILE="$TMP/watchdog.pid"
export WATCH_HELM_AUTH_FILE="$TMP/watchdog-token"
export WATCH_HELM_RUN_DIR="$TMP/helmrun"
export WATCH_FAIL_THRESHOLD=3
export WATCHDOG_INTERVAL=1
export WATCH_STALL_ROUNDS_TO_RESTART=2
# grace 用短值便于测试（2s）
export WATCH_ACTIVE_STALL_GRACE_SEC=2
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
sed 's/^while true; do/while false; do/' "$WATCHDOG" > "$TMP/extracted.sh"
source "$TMP/extracted.sh"

# ---- 覆盖为 mock ----
mock_web_up=0; mock_mcp_up=0; mock_port_pid=""; mock_is_dsh=1
# mcp_probe_sessions mock：返回 "ok N" / "fail" / "notoken"
mock_probe="ok 0"
mcp_probe_sessions() { echo "$mock_probe"; }
web_healthy() { [ "$mock_web_up" = "1" ]; }
mcp_healthy() { [ "$mock_mcp_up" = "1" ]; }
port_pid() { echo "$mock_port_pid"; }
is_dsh() { [ "$mock_is_dsh" = "1" ]; }
RESTART_COUNT=0; SNAPSHOT_COUNT=0
restart_web() { RESTART_COUNT=$((RESTART_COUNT+1)); }
launch_web() { RESTART_COUNT=$((RESTART_COUNT+1)); }
snapshot_diag() { SNAPSHOT_COUNT=$((SNAPSHOT_COUNT+1)); echo "snapshot: $1" >> "$TMP/snapshots.log"; }

# 一轮检查（主循环内联逻辑的副本——与被测脚本同步维护）
tick() {
  ui_ok=0; mcp_ok=0
  port_pid "$WEB_PORT" >/dev/null && is_dsh && web_healthy && ui_ok=1
  mcp_healthy && mcp_ok=1

  if [ "$ui_ok" = "1" ]; then
    [ "$ui_fail" -gt 0 ] && true
    ui_fail=0
    STALL_SINCE=""
    DATAPATH_FAIL=0
  else
    ui_fail=$((ui_fail + 1))
  fi
  if [ "$mcp_ok" = "1" ]; then
    mcp_fail=0
  else
    mcp_fail=$((mcp_fail + 1))
  fi

  if [ "$ui_fail" -ge "$FAIL_THRESHOLD" ] && [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0; mcp_fail=0
    STALL_SINCE=""; DATAPATH_FAIL=0
    snapshot_diag "dual-endpoint-down"
    restart_web
  elif [ "$ui_fail" -ge "$FAIL_THRESHOLD" ]; then
    probe=$(mcp_probe_sessions)
    case "$probe" in
      ok*)
        act=${probe#ok }
        LAST_ACT=$act
        DATAPATH_FAIL=0
        STALL_SINCE=""
        ui_fail=0
        ;;
      notoken)
        if [ "$ui_fail" -ge $((FAIL_THRESHOLD * 2)) ]; then
          ui_fail=0; STALL_SINCE=""; DATAPATH_FAIL=0
          snapshot_diag "ui-stall-no-token"
          restart_web
        fi
        ;;
      fail)
        DATAPATH_FAIL=$((DATAPATH_FAIL + 1))
        [ -z "$STALL_SINCE" ] && STALL_SINCE=$(date +%s)
        now=$(date +%s)
        act=$LAST_ACT
        if [ "$act" -gt 0 ]; then
          elapsed=$((now - STALL_SINCE))
          if [ "$elapsed" -ge "$ACTIVE_STALL_GRACE" ]; then
            ui_fail=0; STALL_SINCE=""; DATAPATH_FAIL=0; LAST_ACT=0
            snapshot_diag "datapath-stall-beyond-grace"
            restart_web
          else
            log "⚠ datapath stall ${DATAPATH_FAIL} 轮（${elapsed}s/${ACTIVE_STALL_GRACE}s 保护期内，${act} 个活跃会话），暂不重启"
          fi
        else
          if [ "$DATAPATH_FAIL" -ge "$STALL_ROUNDS_TO_RESTART" ]; then
            ui_fail=0; STALL_SINCE=""; DATAPATH_FAIL=0
            snapshot_diag "datapath-stall-no-active"
            restart_web
          else
            log "⚠ datapath stall ${DATAPATH_FAIL}/${STALL_ROUNDS_TO_RESTART} 轮、无活跃会话——暂不重启"
          fi
        fi
        ;;
    esac
  elif [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    ui_fail=0; mcp_fail=0
    STALL_SINCE=""; DATAPATH_FAIL=0
    snapshot_diag "mcp-down-ui-up"
    restart_web
  fi
}

echo "== 场景 A：UI fail（≥3 轮）但 sessions_list ok → datapath 活，清 stall 不重启 =="
ui_fail=0; mcp_fail=0; RESTART_COUNT=0; SNAPSHOT_COUNT=0; STALL_SINCE=""; DATAPATH_FAIL=0
mock_web_up=0; mock_mcp_up=1; mock_port_pid="12345"; mock_probe="ok 3"
for i in 1 2 3 4 5; do tick; done
check "A: 5 轮后 RESTART_COUNT=0" test "$RESTART_COUNT" = "0"
check "A: SNAPSHOT_COUNT=0" test "$SNAPSHOT_COUNT" = "0"
# ui_fail 每轮开头先 ++（到达阈值前不 probe），probe ok 后清 0 → 末轮可能停在 1~2
check "A: ui_fail 未达重启阈值（datapath 活→不累计到重启）" test "$ui_fail" -lt "$FAIL_THRESHOLD"
check "A: DATAPATH_FAIL=0" test "$DATAPATH_FAIL" = "0"

echo "== 场景 B：UI fail + sessions_list fail + active=0 → 连续 2 轮 stall → snapshot+restart =="
ui_fail=0; mcp_fail=0; RESTART_COUNT=0; SNAPSHOT_COUNT=0; STALL_SINCE=""; DATAPATH_FAIL=0; LAST_ACT=0
mock_web_up=0; mock_mcp_up=1; mock_port_pid="12345"; mock_probe="fail"
for i in 1 2 3; do tick; done   # 第 3 轮才达 FAIL_THRESHOLD，之后每轮 stall 判定
check "B: 首轮 stall 不重启（RESTART_COUNT=0）" test "$RESTART_COUNT" = "0"
tick  # DATAPATH_FAIL=2（连续 2 轮 stall）→ 重启
check "B: 连续 2 轮 stall 触发重启 (RESTART_COUNT=1)" test "$RESTART_COUNT" = "1"
check "B: snapshot 已拍（datapath-stall-no-active）" test "$SNAPSHOT_COUNT" = "1"
grep -q "datapath-stall-no-active" "$TMP/snapshots.log" && check "B: snapshot reason 正确" true || check "B: snapshot reason 正确" false

echo "== 场景 C：UI fail + sessions_list fail + active>0 within grace → 保护不重启 =="
ui_fail=0; mcp_fail=0; RESTART_COUNT=0; SNAPSHOT_COUNT=0; STALL_SINCE=""; DATAPATH_FAIL=0
mock_web_up=0; mock_mcp_up=1; mock_port_pid="12345"; mock_probe="ok 2"
for i in 1 2 3; do tick; done   # 先建立 LAST_ACT=2（ok 2）
mock_probe="fail"
for i in 1 2 3; do tick; done   # 3 轮 fail，仍在 grace（2s）内
check "C: 保护期内不重启 (RESTART_COUNT=0)" test "$RESTART_COUNT" = "0"
check "C: 保护期内不 snapshot" test "$SNAPSHOT_COUNT" = "0"
check "C: STALL_SINCE 已记录" test -n "$STALL_SINCE"
# fail probe 只在 ui_fail≥3 的轮次触发（前 2 轮 ui_fail=1,2 不 probe）→ 实际累计 1 次
check "C: DATAPATH_FAIL 已累计（≥1）" test "$DATAPATH_FAIL" -ge "1"

echo "== 场景 D：UI fail + sessions_list fail + active>0 beyond grace → snapshot+restart =="
sleep 3  # 等 grace（2s）过期
tick
check "D: 超 grace 触发重启 (RESTART_COUNT=1)" test "$RESTART_COUNT" = "1"
check "D: snapshot 已拍（datapath-stall-beyond-grace）" test "$SNAPSHOT_COUNT" = "1"
grep -q "datapath-stall-beyond-grace" "$TMP/snapshots.log" && check "D: snapshot reason 正确" true || check "D: snapshot reason 正确" false

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
rm -rf "$TMP"
[ "$FAIL" = "0" ]
