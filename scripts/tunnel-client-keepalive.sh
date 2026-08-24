#!/usr/bin/env bash
# tunnel-client-keepalive — ChatGPT Helm 隧道客户端守护
#
# 职责：每 15 秒检查 tunnel-client 健康 + helm daemon (3457) upstream 健康，
# 任一异常时用正确环境（凭据 + 代理 + AUTH）重新拉起。
#
# v2 相对 v1 的修复：
#   - 探针从 /mcp（无条件 401，永远判失败）改为 /healthz（免认证，200=daemon 活）
#   - 隧道健康 = 3458 自身 healthz **且** 3457 upstream healthz（消除假健康：
#     3457 挂时 3458 仍 live 不再被当作健康）
#   - daemon PID 变化检测：daemon 重启（web 重启连带）后 MCP session 失效，
#     主动重启隧道以重新初始化 MCP 会话，消除「UI 已恢复但 connector 仍 502」
#   - 单实例 PID 锁（防多实例 pkill 互杀）
#   - pkill 精确锚定本脚本管理的实例（不误杀 daemon 自管隧道）
#
# 部署（LaunchAgent 常驻）：
#   cp launchd/com.dsh-connector.tunnel-client-keepalive.plist ~/Library/LaunchAgents/
#   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dsh-connector.tunnel-client-keepalive.plist

set -u
TUNNEL_CLIENT="${KEEPALIVE_TUNNEL_BIN:-$HOME/.local/bin/tunnel-client}"
LOG_FILE="${KEEPALIVE_LOG_FILE:-$HOME/.dsh/logs/tunnel-client-keepalive.log}"
STATE_FILE="${KEEPALIVE_STATE_FILE:-$HOME/.dsh/logs/tunnel-client-keepalive.state}"
PID_FILE="${KEEPALIVE_PID_FILE:-$HOME/.dsh/logs/tunnel-client-keepalive.pid}"
MCP_PORT="${HELM_MCP_PORT:-3457}"
HEALTH_PORT="${TUNNEL_HEALTH_PORT:-3458}"
HELM_AUTH_FILE="${HELM_AUTH_FILE:-$HOME/.agent-chatgpt-helm/token}"
TUNNEL_LOG_FILE="${KEEPALIVE_TUNNEL_LOG:-$HOME/.dsh/logs/tunnel-client-manual.log}"
# helm daemon 进程匹配模式（测试可注入隔离模式；默认匹配实际运行中的 daemon 命令行）
DAEMON_PATTERN="${KEEPALIVE_DAEMON_PATTERN:-agent-chatgpt-helm/lib/cli\.js daemon}"
mkdir -p "$(dirname "$LOG_FILE")"

# ---- 单实例锁 ----
acquire_lock() {
  local old_pid
  if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      if ps -ww -p "$old_pid" -o command= 2>/dev/null | grep -q "tunnel-client-keepalive.sh"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已有实例在运行 (pid=${old_pid})，退出" >> "$LOG_FILE"
        # launchd KeepAlive 会立即拉起新实例；sleep 避免空转重启循环
        sleep 60
        exit 0
      fi
    fi
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

# 从私有凭据文件读取（不打印值）。
# CRED_FILE 支持环境变量覆盖（测试注入假凭据；缺省 ~/.dsh/.credentials.yaml）。
# 注意：凭据在每次 start_tunnel 时重新读取（fresh install 时 keepalive 可能先于
# daemon 启动，token 由 daemon 首启自动生成——启动时读一次会拿到空 AUTH）。
CRED_FILE="${CRED_FILE:-$HOME/.dsh/.credentials.yaml}"

read_creds() {
  CONTROL_PLANE_TUNNEL_ID=$(grep '^CONTROL_PLANE_TUNNEL_ID:' "$CRED_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'\''' | tr -d '\r')
  export CONTROL_PLANE_TUNNEL_ID
  CONTROL_PLANE_API_KEY=$(grep '^CONTROL_PLANE_API_KEY:' "$CRED_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'\''' | tr -d '\r')
  export CONTROL_PLANE_API_KEY
  AGENT_CHATGPT_HELM_AUTH=$(cat "$HELM_AUTH_FILE" 2>/dev/null || echo "")
  export AGENT_CHATGPT_HELM_AUTH
}

# 海外 API 需经本地代理（默认 127.0.0.1:7897；可用 HTTPS_PROXY 环境变量覆盖）
export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}"
export NO_PROXY="${NO_PROXY:-127.0.0.1,localhost}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# helm daemon (MCP upstream) 是否健康：/healthz 免认证，200 = 活
mcp_up() {
  curl -fsS --max-time 3 "http://127.0.0.1:${MCP_PORT}/healthz" >/dev/null 2>&1
}

# 隧道自身 healthz 是否 live
tunnel_up() {
  curl -fsS --max-time 3 "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1
}

# 当前 helm daemon pid（无则空）
daemon_pid() {
  pgrep -f "$DAEMON_PATTERN" 2>/dev/null | head -1 | tr -d ' '
}

# 当前本脚本管理的 tunnel-client pid（精确匹配本实例参数，不误伤 daemon 自管隧道）
tunnel_pid() {
  pgrep -f "tunnel-client run .*--mcp.server-url http://127.0.0.1:${MCP_PORT}/mcp" 2>/dev/null | head -1 | tr -d ' '
}

start_tunnel() {
  if [ ! -x "$TUNNEL_CLIENT" ]; then
    log "✗ tunnel-client 二进制不存在: ${TUNNEL_CLIENT}（跳过拉起，请安装后重试）"
    return 1
  fi
  # 每次拉起前刷新凭据/AUTH（daemon 的 token 可能刚刚生成）
  read_creds
  if [ -z "$CONTROL_PLANE_TUNNEL_ID" ] || [ -z "$CONTROL_PLANE_API_KEY" ]; then
    log "✗ 凭据缺失（CONTROL_PLANE_TUNNEL_ID/API_KEY 为空），跳过拉起（下轮重试）"
    return 1
  fi
  if [ -z "$AGENT_CHATGPT_HELM_AUTH" ]; then
    log "⚠ helm daemon token 尚不存在（daemon 未启动/未生成），跳过拉起（下轮重试）"
    return 1
  fi
  log "拉起 tunnel-client"
  nohup "$TUNNEL_CLIENT" run \
    --control-plane.tunnel-id "$CONTROL_PLANE_TUNNEL_ID" \
    --control-plane.api-key env:CONTROL_PLANE_API_KEY \
    --control-plane.poll-timeout=10000ms \
    --control-plane.poll-deadline-guardrail=3000ms \
    --mcp.server-url "http://127.0.0.1:${MCP_PORT}/mcp" \
    --mcp.extra-headers "Authorization: env:AGENT_CHATGPT_HELM_AUTH" \
    --health.listen-addr "127.0.0.1:${HEALTH_PORT}" \
    --log.level=info --log.format=struct-text \
    >> "$TUNNEL_LOG_FILE" 2>&1 &
}

# 杀掉本脚本管理的 tunnel（精确锚定）
kill_tunnel() {
  local pid
  # 循环杀全部匹配实例（防旧僵尸 + 新实例并存时只杀一个）
  for pid in $(pgrep -f "tunnel-client run .*--mcp.server-url http://127.0.0.1:${MCP_PORT}/mcp" 2>/dev/null); do
    kill "$pid" 2>/dev/null || true
  done
  sleep 1
}

# 诊断快照：隧道重建前把现场状态落盘（~/.dsh/logs/diagnostics/<时间戳>/）
# 内容脱敏：tunnel_id 等凭据形态值一律打码，不包含任何凭据明文。
# 保留最近 KEEPALIVE_KEEP_SNAPSHOT 份。
DIAG_DIR="${KEEPALIVE_DIAG_DIR:-$HOME/.dsh/logs/diagnostics}"
snapshot_diag() { # $1=原因
  local ts dir
  ts=$(date '+%Y%m%d-%H%M%S')
  dir="$DIAG_DIR/$ts"
  mkdir -p "$dir"
  {
    echo "time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "reason: $1"
    echo "keepalive pid: $$"
    echo "daemon pid: ${local_daemon_pid:-unknown}"
    echo "last daemon pid: ${LAST_DAEMON_PID:-none}"
    echo "mcp_ok: ${mcp_ok:-0}  tunnel_ok: ${tunnel_ok:-0}"
  } > "$dir/meta.txt" 2>&1
  {
    echo "--- processes ---"
    ps aux | grep -E "bin\.ts web|cli\.js daemon|tunnel-client run" | grep -v grep || echo "(none)"
    echo "--- ports (3080/3457/3458 healthz) ---"
    for p in 3080 3457 3458; do
      echo -n "$p: "
      curl -sS --max-time 2 -o /dev/null -w "%{http_code} %{time_total}s" "http://127.0.0.1:$p/healthz" 2>/dev/null || echo -n "down"
      echo
    done
    echo "--- keepalive log tail ---"
    tail -30 "$LOG_FILE" 2>/dev/null
    echo "--- tunnel log tail ---"
    tail -15 "$TUNNEL_LOG_FILE" 2>/dev/null
  } > "$dir/state.txt" 2>&1
  # 脱敏：凭据形态（sk-/tunnel_/asdk_app_ 后接长串）一律打码
  sed -i '' -E 's/(sk-[A-Za-z0-9]{8})[A-Za-z0-9]+/\1<redacted>/g; s/(tunnel_[A-Za-z0-9]{8})[A-Za-z0-9]+/\1<redacted>/g; s/(asdk_app_[A-Za-z0-9]{8})[A-Za-z0-9]+/\1<redacted>/g' "$dir/state.txt" 2>/dev/null || true
  log "诊断快照已写入 $dir"
  KEEP_SNAPSHOT="${KEEPALIVE_KEEP_SNAPSHOT:-10}"
  ls -1dt "$DIAG_DIR"/[0-9]* 2>/dev/null | tail -n +$((KEEP_SNAPSHOT + 1)) | xargs -r rm -rf
}

# 防抖：重建限速（60s 内最多重建 3 次，防 daemon 来回切换时疯狂重建）
RESTART_TIMES_FILE="${KEEPALIVE_RESTART_TIMES_FILE:-$HOME/.dsh/logs/tunnel-client-keepalive.restarts}"
throttle_ok() {
  local now n
  now=$(date +%s)
  if [ -f "$RESTART_TIMES_FILE" ]; then
    awk -v now="$now" '{ if (now - $1 <= 60) print }' "$RESTART_TIMES_FILE" > "$RESTART_TIMES_FILE.tmp" && mv "$RESTART_TIMES_FILE.tmp" "$RESTART_TIMES_FILE"
  fi
  n=$(wc -l < "$RESTART_TIMES_FILE" 2>/dev/null || echo 0)
  if [ "$n" -ge 3 ]; then
    log "⚠ 60s 内已重建 $n 次，限速跳过本轮重建（防抖动）"
    return 1
  fi
  date +%s >> "$RESTART_TIMES_FILE"
  return 0
}

acquire_lock

# 状态文件：记录上一次见过的 daemon pid（daemon 重启时主动重启隧道重连 MCP）
LAST_DAEMON_PID=""
[ -f "$STATE_FILE" ] && LAST_DAEMON_PID=$(cat "$STATE_FILE" 2>/dev/null || echo "")

log "==== tunnel-client-keepalive v2 启动 (pid $$) ===="
while true; do
  local_daemon_pid=$(daemon_pid)
  mcp_ok=0; tunnel_ok=0
  mcp_up && mcp_ok=1
  tunnel_up && tunnel_ok=1

  # 判定逻辑：
  # 1. daemon 重启（pid 变化）→ 旧隧道 MCP session 失效 → 重启隧道
  # 2. 隧道自身挂了 → 重启
  # 3. 3457 upstream 挂但隧道活着 → 不杀隧道（daemon 恢复时隧道自动转发），
  #    但记录状态；若隧道自己也不健康则一并重启
  need_restart=0
  # LAST_DAEMON_PID 为空（state 文件缺失/首见 daemon）时不得触发「daemon 重启」判定
  # ——否则每次循环都误判重启 → 隧道循环被杀重建，控制面永远连不稳，
  # ChatGPT 侧任务全部丢失。首见只建立基线，隧道死活由 tunnel_ok 兜底。
  # daemon 完全消失（local_daemon_pid 为空）时也不得触发「重启」判定
  # ——web 重启窗口内 daemon 短暂缺席属正常，此时杀健康隧道只会制造抖动；
  # 等 daemon 以新 pid 回归时再重建一次（MCP session 确实失效了）。
  if [ -n "$local_daemon_pid" ] && [ -n "$LAST_DAEMON_PID" ] && [ "$LAST_DAEMON_PID" != "$local_daemon_pid" ]; then
    log "检测到 helm daemon 重启（pid $LAST_DAEMON_PID → ${local_daemon_pid}），重启隧道以重新初始化 MCP 会话"
    need_restart=1
  fi
  if [ "$tunnel_ok" != "1" ]; then
    log "隧道 healthz 不健康（3458），重启"
    need_restart=1
  fi
  # 无论是否重启隧道，本轮探测后立即更新 daemon pid 基线。
  # 原实现只在健康分支（else）写 state，一旦进过重启分支就永远不再写，
  # LAST_DAEMON_PID 永远不等于实际 pid → 每 15s 误判重启 → 隧道循环重建。
  if [ -n "$local_daemon_pid" ]; then
    echo "$local_daemon_pid" > "$STATE_FILE"
    LAST_DAEMON_PID="$local_daemon_pid"
  fi

  if [ "$need_restart" = "1" ]; then
    if throttle_ok; then
      snapshot_diag "tunnel-restart"
      kill_tunnel
      start_tunnel
      # 更新状态（等待隧道健康确认）
      sleep 2
      if tunnel_up; then
        log "✓ tunnel-client 已就绪"
      else
        log "⚠ tunnel-client 启动后 2s 未就绪（下轮重试）"
      fi
    fi
  else
    # 健康时无需动作（daemon pid 基线已在探测后无条件更新）
    if [ "$mcp_ok" != "1" ]; then
      log "3457 upstream 不可达但隧道自身健康（daemon 恢复中？），保持隧道运行"
    fi
  fi
  sleep 15
done
log "==== tunnel-client-keepalive 退出 ===="
