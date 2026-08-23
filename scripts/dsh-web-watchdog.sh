#!/usr/bin/env bash
# dsh-web-watchdog — dsh web 看门狗哨兵 v2（2026-08-23 稳定性重构）
#
# 职责：每 N 秒检查 dsh web (3080) 与 helm MCP daemon (3457) 健康，仅在
# **连续多次**双端点均不健康时才做受控重启。重启顺序可证明：
#   1) SIGTERM 旧 web（等待端口释放，超时 SIGKILL）
#   2) 清理残留 helm daemon（SIGTERM → 5s → SIGKILL）
#   3) 删除陈旧 daemon.sock
#   4) 带完整凭据/代理 env 拉起新 web
#   5) 验证 3080 + 3457/healthz 双就绪后才宣告成功
#
# v2 相对 v1 的修复：
#   - 单次 3s 健康检查失败即 kill → 3 次连续失败 + UI/MCP 双交叉确认才动作
#     （高负载下 web 短暂不响应不再被误杀；3457 仍健康说明 ChatGPT 链路还通，
#      绝不 kill）
#   - 修复 "停止卡死实例 pid=" 空 pid bug（一次 lsof 取 pid 复用）
#   - 修复 web 被 kill 后 helm daemon 成孤儿 → 新 web attach 卡死 daemon 的
#     死锁：重启前显式清理残留 daemon 与陈旧 socket
#   - 单实例锁升级为 PID 文件 + 存活校验（防双实例竞争）
#
# 部署（LaunchAgent 常驻）：
#   cp launchd/com.dsh-connector.dsh-web-watchdog.plist ~/Library/LaunchAgents/
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dsh-connector.dsh-web-watchdog.plist
#
# 手动运行一次：./dsh-web-watchdog.sh --once
# 日志：~/.dsh/logs/dsh-web-watchdog.log

set -u

WEB_PORT="${WATCH_WEB_PORT:-3080}"
MCP_PORT="${WATCH_MCP_PORT:-3457}"
INTERVAL="${WATCHDOG_INTERVAL:-10}"
# 连续失败多少次才判定需要重启（每次间隔 INTERVAL 秒，3 次 ≈ 30s 容错窗口）
FAIL_THRESHOLD="${WATCH_FAIL_THRESHOLD:-3}"
# web 被 SIGTERM 后等待端口释放的最长时间
WEB_DIE_TIMEOUT="${WATCH_WEB_DIE_TIMEOUT:-15}"
# daemon 被 SIGTERM 后等待退出的最长时间
DAEMON_DIE_TIMEOUT="${WATCH_DAEMON_DIE_TIMEOUT:-5}"
# DSH checkout 目录。仓库跨机器同步，禁止写死本机绝对路径：
HARNESS_DIR="${DSH_HARNESS_DIR:-$HOME/deepseek/deepseek-harness}"
HELM_RUN_DIR="${WATCH_HELM_RUN_DIR:-$HOME/.agent-chatgpt-helm/run}"
HELM_SOCK="$HELM_RUN_DIR/daemon.sock"
LOG_DIR="${WATCH_LOG_DIR:-$HOME/.dsh/logs}"
LOG_FILE="$LOG_DIR/dsh-web-watchdog.log"
PID_FILE="${WATCH_PID_FILE:-$HOME/.dsh/.dsh-web-watchdog.pid}"
# 测试可覆盖 node 可执行文件（默认 harness 自带 node22）
NODE_BIN="${WATCH_NODE_BIN:-$HARNESS_DIR/.tools/node22/bin/node}"

export PATH="$HARNESS_DIR/.tools/node22/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 从私有凭据文件注入 ChatGPT Helm 隧道环境变量（文件不入库，脚本本身不含密钥值）
CRED_FILE="$HOME/.dsh/.credentials.yaml"
if [ -f "$CRED_FILE" ]; then
  export CONTROL_PLANE_TUNNEL_ID=$(grep '^CONTROL_PLANE_TUNNEL_ID:' "$CRED_FILE" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'\''' | tr -d '\r')
  export CONTROL_PLANE_API_KEY=$(grep '^CONTROL_PLANE_API_KEY:' "$CRED_FILE" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'\''' | tr -d '\r')
fi

# 海外 API 直连不通时必须走本地代理（Clash Verge 7897），否则 tunnel-client 控制面轮询超时
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
export ALL_PROXY="${ALL_PROXY:-socks5://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8}"

mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ---- 单实例锁（PID 文件 + 存活校验）----
acquire_lock() {
  if [ -f "$PID_FILE" ]; then
    local old_pid
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      # 锁持有者还活着：确认它确实是 watchdog（防 PID 复用误判）
      if ps -ww -p "$old_pid" -o command= 2>/dev/null | grep -q "dsh-web-watchdog.sh"; then
        log "已有实例在运行（pid=$old_pid），退出"
        exit 0
      fi
    fi
    log "旧锁持有者 pid=$old_pid 已失效，接管"
  fi
  echo $$ > "$PID_FILE"
}
release_lock() {
  if [ -f "$PID_FILE" ]; then
    local cur
    cur=$(cat "$PID_FILE" 2>/dev/null || echo "")
    [ "$cur" = "$$" ] && rm -f "$PID_FILE"
  fi
}
trap 'release_lock' EXIT

# ---- 探针 ----
# 端口是否被监听（返回监听 pid，无则空）
port_pid() {
  lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -1
}

# 探针超时（毫秒级影响不大，秒级单位；测试可覆盖）
PROBE_TIMEOUT="${WATCH_PROBE_TIMEOUT:-3}"

# web HTTP 是否响应
web_healthy() {
  curl -fsS --max-time "$PROBE_TIMEOUT" "http://127.0.0.1:${WEB_PORT}/" >/dev/null 2>&1
}

# helm daemon MCP 是否响应（/healthz 免认证，200=daemon 活）
mcp_healthy() {
  curl -fsS --max-time "$PROBE_TIMEOUT" "http://127.0.0.1:${MCP_PORT}/healthz" >/dev/null 2>&1
}

# 端口监听者是否确实是 dsh web
is_dsh() {
  local pid cmd
  pid=$(port_pid "$WEB_PORT")
  [ -z "$pid" ] && return 1
  cmd=$(ps -ww -p "$pid" -o command= 2>/dev/null)
  case "$cmd" in
    *"bin.ts web"*|*"dsh web"*|*" --profile web "*) return 0 ;;
    *) return 1 ;;
  esac
}

# 清理残留 helm daemon（web 被 kill 后可能成孤儿，需显式清理否则新 web attach 卡死 daemon）
cleanup_orphan_daemon() {
  local pids pid
  # 匹配 agent-chatgpt-helm 的 daemon 进程（精确锚定，绝不误伤其他 node 进程）
  pids=$(pgrep -f 'agent-chatgpt-helm/lib/cli\.js daemon' 2>/dev/null || true)
  if [ -z "$pids" ]; then
    # 兜底：3457 端口监听者若不是当前 web 的子进程也清理
    local lp lppid webpid
    webpid=$(port_pid "$WEB_PORT")
    lp=$(port_pid "$MCP_PORT")
    if [ -n "$lp" ]; then
      lppid=$(ps -ww -p "$lp" -o ppid= 2>/dev/null | tr -d ' ')
      if [ -z "$webpid" ] || [ "$lppid" != "$webpid" ]; then
        log "3457 监听者 pid=$lp (ppid=$lppid) 非当前 web 子进程，视为残留清理"
        kill "$lp" 2>/dev/null || true
        pids="$lp"
      fi
    fi
  fi
  if [ -n "$pids" ]; then
    for pid in $pids; do
      log "清理残留 helm daemon pid=$pid"
      kill "$pid" 2>/dev/null || true
    done
    # 等待退出，超时 SIGKILL
    local waited=0
    while [ "$waited" -lt "$DAEMON_DIE_TIMEOUT" ]; do
      local still
      still=""
      for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && still="$still $pid"
      done
      [ -z "$still" ] && break
      sleep 1
      waited=$((waited + 1))
    done
    for pid in $pids; do
      kill -0 "$pid" 2>/dev/null && { log "daemon pid=$pid 未退出，SIGKILL"; kill -9 "$pid" 2>/dev/null || true; }
    done
  fi
  # 无论是否有残留 daemon 进程，陈旧 socket 一律清理（确认无活进程持有后才删，
  # 上面的 kill 循环已保证；无进程时直接删——陈旧文件无人持有，安全）
  if [ -S "$HELM_SOCK" ] || [ -e "$HELM_SOCK" ]; then
    log "删除陈旧 daemon.sock"
    rm -f "$HELM_SOCK"
  fi
}

# 拉起 dsh web（带完整 env），等待 3080 + 3457 双就绪
launch_web() {
  log "拉起 dsh web（cwd=$HARNESS_DIR）"
  ( cd "$HARNESS_DIR" && nohup "$NODE_BIN" --import tsx/esm apps/cli/src/bin.ts web --no-open \
      >> "$LOG_DIR/dsh-web-watchdog-launch.log" 2>&1 & )
  local sec=0
  while [ "$sec" -lt 40 ]; do
    sleep 2
    sec=$((sec + 2))
    if port_pid "$WEB_PORT" >/dev/null && is_dsh; then
      # 3080 就绪后还要等 3457 MCP 就绪（daemon 由 web 插件拉起，可能晚几秒）
      if mcp_healthy; then
        log "✓ dsh web 已拉起，3080 与 3457 MCP 均就绪（${sec}s）"
        return 0
      fi
      log "3080 已就绪，等待 3457 MCP（${sec}s）..."
    fi
  done
  log "✗ 40 秒内未双就绪（3080=$(port_pid "$WEB_PORT" >/dev/null && echo up || echo down)，3457=$(mcp_healthy && echo up || echo down)），下轮重试"
  return 0
}

# 受控重启：kill web → 清 daemon → 删 sock → 拉起 → 双验证
restart_web() {
  local pid
  pid=$(port_pid "$WEB_PORT")
  if [ -n "$pid" ]; then
    log "⚠ 双端点持续不健康（${FAIL_THRESHOLD} 次），停止 web pid=$pid"
    kill "$pid" 2>/dev/null || true
    # 等待端口释放（web 优雅退出；优雅退出可能较慢，故给足窗口）
    local waited=0
    while [ "$waited" -lt "$WEB_DIE_TIMEOUT" ]; do
      [ -z "$(port_pid "$WEB_PORT")" ] && break
      sleep 1
      waited=$((waited + 1))
    done
    if port_pid "$WEB_PORT" >/dev/null; then
      log "web pid=$pid ${WEB_DIE_TIMEOUT}s 未退出，SIGKILL"
      kill -9 "$pid" 2>/dev/null || true
      sleep 2
    fi
  fi
  # 清理残留 daemon 与陈旧 socket（保证新 daemon bind 不被旧文件/旧进程阻塞）
  cleanup_orphan_daemon
  launch_web
}

# ---- 主循环 ----
once=0
for a in "$@"; do
  [ "$a" = "--once" ] && once=1
done

acquire_lock
log "==== dsh-web-watchdog v2 启动 (pid $$) 间隔=${INTERVAL}s 阈值=${FAIL_THRESHOLD} ===="

ui_fail=0
mcp_fail=0
while true; do
  ui_ok=0; mcp_ok=0
  port_pid "$WEB_PORT" >/dev/null && is_dsh && web_healthy && ui_ok=1
  mcp_healthy && mcp_ok=1

  if [ "$ui_ok" = "1" ]; then
    [ "$ui_fail" -gt 0 ] && log "web 健康恢复（此前连续失败 ${ui_fail} 次）"
    ui_fail=0
  else
    ui_fail=$((ui_fail + 1))
  fi
  if [ "$mcp_ok" = "1" ]; then
    [ "$mcp_fail" -gt 0 ] && log "3457 MCP 健康恢复（此前连续失败 ${mcp_fail} 次）"
    mcp_fail=0
  else
    mcp_fail=$((mcp_fail + 1))
  fi

  if [ "$ui_fail" -ge "$FAIL_THRESHOLD" ] && [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    # 双端点都连续失败 → 真死锁，重启
    ui_fail=0; mcp_fail=0
    restart_web
  elif [ "$ui_fail" -ge "$FAIL_THRESHOLD" ]; then
    # 仅 UI 不健康但 MCP 还通：ChatGPT 链路不受影响，只告警不 kill
    log "⚠ web UI 连续 ${ui_fail} 次不健康但 3457 MCP 健康（可能是高负载），不重启（保护活跃工具调用）"
    ui_fail=0
  elif [ "$mcp_fail" -ge "$FAIL_THRESHOLD" ]; then
    # 仅 MCP 不健康但 UI 通：daemon 可能卡死/未拉起，重启 web（连带 daemon 重启）
    log "⚠ 3457 MCP 连续 ${mcp_fail} 次不健康但 web UI 健康，重启 web 以恢复 daemon"
    ui_fail=0; mcp_fail=0
    restart_web
  fi

  # 兜底：web 不在但无失败计数（如手动关闭）→ 直接拉起
  if [ "$ui_fail" = "1" ] && [ -z "$(port_pid "$WEB_PORT")" ]; then
    ui_fail=0
    launch_web
  fi

  [ "$once" = "1" ] && break
  sleep "$INTERVAL"
done
log "==== dsh-web-watchdog 退出 ===="
