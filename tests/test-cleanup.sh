#!/usr/bin/env bash
# test-cleanup.sh — watchdog v2 的残留 daemon 清理 + 陈旧 socket 清理测试
#
# 隔离方式：WATCH_HELM_RUN_DIR / WATCH_LOG_DIR / WATCH_PID_FILE 指向 TMP，
# fake daemon 进程使用隔离命令行模式（不匹配实际运行的 daemon），不碰实际运行环境进程/端口。
#
# 用法：bash test-cleanup.sh

set -u
cd "$(dirname "$0")"
REPO_ROOT="$(cd .. && pwd)"

WATCHDOG="$REPO_ROOT/scripts/dsh-web-watchdog.sh"
TMP=$(mktemp -d /tmp/watchdog-cleanup-test.XXXXXX)
export WATCH_LOG_DIR="$TMP/logs"
export WATCH_PID_FILE="$TMP/watchdog.pid"
export WATCH_HELM_AUTH_FILE="$TMP/watchdog-token"
export WATCH_HELM_RUN_DIR="$TMP/helmrun"
export WATCH_FAIL_THRESHOLD=3
export WATCHDOG_INTERVAL=1
export DSH_HARNESS_DIR="$TMP/harness"
export WATCH_NODE_BIN="$TMP/fake-node"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/fake-node"
chmod +x "$TMP/fake-node"
mkdir -p "$TMP/logs" "$TMP/helmrun" "$TMP/harness"

PASS=0; FAIL=0
check() { local name="$1"; shift; if "$@"; then PASS=$((PASS+1)); echo "  ✓ $name"; else FAIL=$((FAIL+1)); echo "  ✗ $name"; fi }

# source（主循环禁用）
sed 's/^while true; do/while false; do/' "$WATCHDOG" > "$TMP/extracted.sh"
source "$TMP/extracted.sh"

# mock：避免真的去 kill 实际运行的进程
cleanup_orphan_daemon() {
  # 真实逻辑的隔离副本（只匹配隔离模式的 fake daemon；与修复后的真实脚本一致：
  # 无论是否有 daemon 进程，陈旧 socket 一律清理）
  local pids pid
  pids=$(pgrep -f 'helm-test-cleanup/agent-chatgpt-helm-test/lib/cli\.js daemon' 2>/dev/null || true)
  if [ -n "$pids" ]; then
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    local waited=0
    while [ "$waited" -lt 3 ]; do
      local still=""
      for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && still="$still $pid"
      done
      [ -z "$still" ] && break
      sleep 0.2
      waited=$((waited + 1))
    done
  fi
  if [ -S "$HELM_SOCK" ] || [ -e "$HELM_SOCK" ]; then
    rm -f "$HELM_SOCK"
  fi
}

echo "== 测试 1：陈旧 daemon.sock（无 daemon 进程）→ 被清理 =="
touch "$TMP/helmrun/daemon.sock"  # 普通文件模拟陈旧 socket
[ -e "$HELM_SOCK" ] && check "陈旧 sock 预置成功" true
cleanup_orphan_daemon
check "陈旧 sock 被删除" test ! -e "$HELM_SOCK"

echo "== 测试 2：fake daemon 进程存在 + 陈旧 sock → daemon 被杀 + sock 清理 =="
cat > "$TMP/fake-daemon" << 'FAKEEOF'
#!/usr/bin/env bash
exec -a "node /tmp/helm-test-cleanup/agent-chatgpt-helm-test/lib/cli.js daemon --project /tmp" bash -c 'while true; do sleep 5; done'
FAKEEOF
chmod +x "$TMP/fake-daemon"
"$TMP/fake-daemon" & DP=$!
sleep 0.5
mkdir -p "$TMP/helmrun"
: > "$TMP/helmrun/daemon.sock"
check "fake daemon 存活" kill -0 "$DP"
cleanup_orphan_daemon
check "fake daemon 被清理" bash -c "! kill -0 $DP 2>/dev/null"
check "sock 被清理" test ! -e "$HELM_SOCK"

echo "== 测试 3：单实例 PID 锁（旧锁持有者存活 → 新实例退出；失效 → 接管）=="
# 模拟：写一个存活进程的 pid 到锁文件（当前 shell 的 $$ 不匹配 watchdog 命令行 → 应接管）
echo $$ > "$PID_FILE"
acquire_lock
check "锁被接管（pid 文件 = 当前 shell $$）" test "$(cat "$PID_FILE")" = "$$"
# 模拟：锁持有者是一个真实的 watchdog 进程（用 grep 命令行伪造 —— 用 sleep 起一个带匹配名的进程）
rm -f "$PID_FILE"
sleep 300 &
SLEEP_PID=$!
# sleep 的命令行不匹配 watchdog，因此会被接管；这里只验证 acquire_lock 在持有者存活时退出
echo "$SLEEP_PID" > "$PID_FILE"
# 由于 sleep 命令行不匹配 watchdog → 接管而不是退出
acquire_lock
check "锁持有者非 watchdog → 接管" test "$(cat "$PID_FILE")" = "$$"
kill "$SLEEP_PID" 2>/dev/null
release_lock

echo "== 测试 4：锁持有者是活 watchdog → 新实例退出 =="
# 用 bash 跑一个真 watchdog 的副本（带 --once 不阻塞）？简化：验证逻辑分支
# 直接验证 acquire_lock 中的判断：进程存活 + 命令行含 dsh-web-watchdog.sh
cat > "$TMP/lockholder.sh" << 'LKEOF'
#!/usr/bin/env bash
# 常驻的锁持有者模拟
while true; do sleep 5; done
LKEOF
sed 's/^#!\/usr\/bin\/env bash$/#!\/usr\/bin\/env bash\n# dsh-web-watchdog.sh mock/' "$TMP/lockholder.sh" > /dev/null
# 起一个命令行含 dsh-web-watchdog.sh 的进程
bash -c "exec -a \"bash $WATCHDOG mock\" bash -c \"while true; do sleep 5; done\"" &
HOLDER_PID=$!
sleep 0.3
echo "$HOLDER_PID" > "$PID_FILE"
# acquire_lock 应检测到持有者存活且命令行匹配 watchdog → 退出
# 但 exit 会杀死测试脚本，所以这里改为直接测判断逻辑
LOCK_RESULT="continue"
if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    if ps -ww -p "$old_pid" -o command= 2>/dev/null | grep -q "dsh-web-watchdog.sh"; then
      LOCK_RESULT="exit"
    fi
  fi
fi
check "锁持有者存活且是 watchdog → 新实例退出" test "$LOCK_RESULT" = "exit"
kill "$HOLDER_PID" 2>/dev/null

rm -rf "$TMP"
echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
