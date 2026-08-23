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
  local old_pid
  if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      # 锁持有者还活着：确认它确实是 watchdog（防 PID 复用误判）
      if ps -ww -p "$old_pid" -o command= 2>/dev/null | grep -q "dsh-web-watchdog.sh"; then
        log "已有实例在运行 (pid=${old_pid})，退出"
        exit 0
      fi
    fi
    log "旧锁持有者 pid=$old_pid 已失效，接管"
  fi
  echo $$ > "$PID_FILE"
}
release_lock() {
  local cur
  if [ -f "$PID_FILE" ]; then
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

# ---- liveness / stall detection（v3）----
# helm daemon 的 MCP auth token（daemon 首启自动生成；不存在时返回 -1 未知）
HELM_AUTH_FILE="${WATCH_HELM_AUTH_FILE:-$HOME/.agent-chatgpt-helm/token}"
# 活跃会话保护宽限期：activeSessions>0 且 datapath stall 时，超过该秒数仍不恢复则强制重启
ACTIVE_STALL_GRACE="${WATCH_ACTIVE_STALL_GRACE_SEC:-300}"
# 无活跃会话时连续 stall 轮数（超过即重启）
STALL_ROUNDS_TO_RESTART="${WATCH_STALL_ROUNDS_TO_RESTART:-2}"

# MCP datapath probe：initialize 握手 → sessions_list（只读）。
# sessions_list 走 daemon → adapter → DSH session 完整数据链，比 /healthz（仅 daemon 进程
# 活性）更接近真实 runtime 活性：web 假死/daemon 卡死/DSH runtime 挂都会让它失败。
# 返回（stdout 多行）：
#   first line: "ok <activeSessions>"  数据链活，且给出 running 会话数
#   first line: "fail"                 数据链失败（initialize 或 sessions_list 失败）
#   first line: "notoken"              无 token（无法探测，按保守处理）
# token 通过 chmod 600 临时 header 文件传给 curl（-H @file），不进进程 argv。
mcp_probe_sessions() {
  local tok hdr sid out act
  tok=$(cat "$HELM_AUTH_FILE" 2>/dev/null || echo "")
  [ -z "$tok" ] && { echo "notoken"; return 1; }
  hdr=$(mktemp)
  chmod 600 "$hdr"
  printf 'Authorization: Bearer %s\n' "$tok" > "$hdr"
  sid=$(curl -sS --max-time 5 -D - -H "@$hdr" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -X POST "http://127.0.0.1:${MCP_PORT}/mcp" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"dsh-watchdog","version":"3"}}}' 2>/dev/null \
    | grep -i "^mcp-session-id:" | tr -d '\r' | awk '{print $2}')
  if [ -z "$sid" ]; then
    rm -f "$hdr"
    echo "fail"
    return 1
  fi
  out=$(curl -sS --max-time 5 -H "@$hdr" -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" -H "Mcp-Session-Id: $sid" \
    -X POST "http://127.0.0.1:${MCP_PORT}/mcp" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"sessions_list","arguments":{}}}' 2>/dev/null)
  rm -f "$hdr"
  act=$(echo "$out" | grep -o '"status":"running"' | wc -l | tr -d ' ')
  if echo "$out" | grep -q '"sessions"'; then
    echo "ok ${act:-0}"
    return 0
  fi
  echo "fail"
  return 1
}

# 故障诊断快照：自愈动作前把现场状态落盘（~/.dsh/logs/diagnostics/<时间戳>/）
# 内容不包含任何凭据值（token 只记录存在性）。
DIAG_DIR="${WATCH_DIAG_DIR:-$LOG_DIR/diagnostics}"
snapshot_diag() { # $1=原因
  local ts dir
  ts=$(date '+%Y%m%d-%H%M%S')
  dir="$DIAG_DIR/$ts"
  mkdir -p "$dir"
  {
    echo "time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "reason: $1"
    echo "watchdog pid: $$"
    echo "token exists: $([ -f "$HELM_AUTH_FILE" ] && echo yes || echo no)"
    echo "--- launchctl (dsh/deepseek/helm) ---"
    launchctl list 2>/dev/null | grep -iE "dsh|deepseek|helm" || echo "(none)"
    echo "--- processes ---"
    ps aux | grep -E "bin\.ts web|cli\.js daemon|tunnel-client run" | grep -v grep || echo "(none)"
    echo "--- ports (3080/3457/3458 healthz) ---"
    for p in 3080 3457 3458; do
      echo -n "$p: "
      curl -sS --max-time 2 -o /dev/null -w "%{http_code} %{time_total}s" "http://127.0.0.1:$p/healthz" 2>/dev/null || echo -n "down"
      echo
    done
    echo "--- watchdog log tail ---"
    tail -30 "$LOG_FILE" 2>/dev/null
    echo "--- keepalive log tail ---"
    tail -20 "$LOG_DIR/tunnel-client-keepalive.log" 2>/dev/null
    echo "--- tunnel log tail ---"
    tail -10 "$LOG_DIR/tunnel-client-manual.log" 2>/dev/null
  } > "$dir/state.txt" 2>&1
  # 脱敏：凭据形态（sk-/tunnel_/asdk_app_ 后接长串）一律打码
  sed -i '' -E 's/(sk-[A-Za-z0-9]{8})[A-Za-z0-9]+/\1<redacted>/g; s/(tunnel_[A-Za-z0-9]{8})[A-Za-z0-9]+/\1<redacted>/g; s/(asdk_app_[A-Za-z0-9]{8})[A-Za-z0-9]+/\1<redacted>/g' "$dir/state.txt" 2>/dev/null || true
  log "诊断快照已写入 $dir"
  KEEP_SNAPSHOT="${WATCH_KEEP_SNAPSHOT:-10}"
  ls -1dt "$DIAG_DIR"/[0-9]* 2>/dev/null | tail -n +$((KEEP_SNAPSHOT + 1)) | xargs -r rm -rf
}

# 清理残留 helm daemon（web 被 kill 后可能成孤儿，需显式清理否则新 web attach 卡死 daemon）
cleanup_orphan_daemon() {
  local pids pid lp lppid webpid waited still
  # 匹配 agent-chatgpt-helm 的 daemon 进程（精确锚定，绝不误伤其他 node 进程）
  pids=$(pgrep -f 'agent-chatgpt-helm/lib/cli\.js daemon' 2>/dev/null || true)
  if [ -z "$pids" ]; then
    # 兜底：3457 端口监听者若不是当前 web 的子进程也清理
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
    waited=0
    while [ "$waited" -lt "$DAEMON_DIE_TIMEOUT" ]; do
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
  local pid waited
  pid=$(port_pid "$WEB_PORT")
  if [ -n "$pid" ]; then
    log "⚠ 双端点持续不健康（${FAIL_THRESHOLD} 次），停止 web pid=$pid"
    kill "$pid" 2>/dev/null || true
    # 等待端口释放（web 优雅退出；优雅退出可能较慢，故给足窗口）
    waited=0
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
STALL_SINCE=""
DATAPATH_FAIL=0
LAST_ACT=0
while true; do
  ui_ok=0; mcp_ok=0
  port_pid "$WEB_PORT" >/dev/null && is_dsh && web_healthy && ui_ok=1
  mcp_healthy && mcp_ok=1

  if [ "$ui_ok" = "1" ]; then
    [ "$ui_fail" -gt 0 ] && log "web 健康恢复（此前连续失败 ${ui_fail} 次）"
    ui_fail=0
    # UI 恢复即清 stall（datapath 也视为恢复，下轮会重新探测）
    STALL_SINCE=""
    DATAPATH_FAIL=0
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
    # 双端点都连续失败 → 真死锁，重启（先快照）
    ui_fail=0; mcp_fail=0
    STALL_SINCE=""; DATAPATH_FAIL=0
    snapshot_diag "dual-endpoint-down"
    restart_web
  elif [ "$ui_fail" -ge "$FAIL_THRESHOLD" ]; then
    # 仅 UI 不健康但 MCP healthz 正常：MCP healthz 只是 daemon 进程活性，
    # 不能代表 session runtime 数据链。用 sessions_list（走 daemon→adapter→DSH）
    # 探测真实 datapath：成功=活（清 stall）；连续失败=datapath stall。
    probe=$(mcp_probe_sessions)
    case "$probe" in
      ok*)
        # datapath 活：会话数据链通，只是 web UI 探针慢/超时（高负载或长任务），不重启
        act=${probe#ok }
        LAST_ACT=$act
        if [ "$DATAPATH_FAIL" -gt 0 ] || [ -n "$STALL_SINCE" ]; then
          log "✓ datapath 恢复（sessions_list 成功，${act} 个 running 会话），清 stall"
        fi
        DATAPATH_FAIL=0
        STALL_SINCE=""
        ui_fail=0
        ;;
      notoken)
        # 无 token：无法探测数据链，保守处理——沿用既有阈值逻辑（无活跃会话信息时
        # 按翻倍阈值重启，避免永久不动作）
        log "⚠ web UI 连续 ${ui_fail} 次不健康且无 token 无法探测 datapath（保守按无活跃处理）"
        if [ "$ui_fail" -ge $((FAIL_THRESHOLD * 2)) ]; then
          log "✗ web UI 连续 ${ui_fail} 次不健康、datapath 不可探测——快照后重启"
          ui_fail=0; STALL_SINCE=""; DATAPATH_FAIL=0
          snapshot_diag "ui-stall-no-token"
          restart_web
        fi
        ;;
      fail)
        # datapath stall 累计
        DATAPATH_FAIL=$((DATAPATH_FAIL + 1))
        [ -z "$STALL_SINCE" ] && STALL_SINCE=$(date +%s)
        now=$(date +%s)
        act=$LAST_ACT
        if [ "$act" -gt 0 ]; then
          # 有活跃会话：保护窗口内不重启，超 grace 仍 stall 则强制重启
          elapsed=$((now - STALL_SINCE))
          if [ "$elapsed" -ge "$ACTIVE_STALL_GRACE" ]; then
            log "✗ datapath stall 已 ${elapsed}s（活跃会话保护期 ${ACTIVE_STALL_GRACE}s 已过），快照后重启"
            ui_fail=0; STALL_SINCE=""; DATAPATH_FAIL=0; LAST_ACT=0
            snapshot_diag "datapath-stall-beyond-grace"
            restart_web
          else
            log "⚠ datapath stall ${DATAPATH_FAIL} 轮（${elapsed}s/${ACTIVE_STALL_GRACE}s 保护期内，${act} 个活跃会话），暂不重启"
          fi
        else
          # 无活跃会话：连续 2 轮 stall 即重启
          if [ "$DATAPATH_FAIL" -ge "$STALL_ROUNDS_TO_RESTART" ]; then
            log "✗ datapath stall 连续 ${DATAPATH_FAIL} 轮、无活跃会话——判定 web 假死，快照后重启"
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
    # 仅 MCP 不健康但 UI 通：daemon 可能卡死/未拉起，重启 web（连带 daemon 重启，先快照）
    log "⚠ 3457 MCP 连续 ${mcp_fail} 次不健康但 web UI 健康，重启 web 以恢复 daemon"
    ui_fail=0; mcp_fail=0
    STALL_SINCE=""; DATAPATH_FAIL=0
    snapshot_diag "mcp-down-ui-up"
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
