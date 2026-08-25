#!/usr/bin/env bash
# install.sh — dsh-chatgpt-connector 部署（macOS）
#
# 用法：
#   ./install.sh                 # 检查依赖 + 安装 LaunchAgent + 合并 patch + 输出指引
#   [环境变量覆盖]
#     DSH_HARNESS_DIR=/path/to/deepseek-harness    # 覆盖 DSH checkout 路径（默认 $HOME/deepseek/deepseek-harness）
#     INSTALL_SKIP_SERVICES=1                      # 只检查依赖与配置，不装 launchd
#     HARNESS_NODE_BIN=/path/to/node               # 覆盖 node 路径（默认 harness 自带 node22）
#
# 前置条件（见 README.md《前置条件》）：
#   - macOS 14+，Node 22+，已 clone deepseek-harness 并安装依赖
#   - 已安装: dsh CLI、tunnel-client、serena（uv tool install -p 3.13 serena-agent）
#   - 已在 OpenAI Platform 创建本机专属 Tunnel + API Key（每台机器独立隧道）
#   - 本地代理监听 127.0.0.1:7897（海外 API 需走代理）
#
# 幂等：重复运行安全；已安装项跳过，不重复 bootstrap。

set -u
# 仓库根（脚本在 scripts/ 下，../ 即仓库根）
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME"
HARNESS_DIR="${DSH_HARNESS_DIR:-$HOME/deepseek/deepseek-harness}"
NODE_BIN="${HARNESS_NODE_BIN:-$HARNESS_DIR/.tools/node22/bin/node}"
CRED_FILE="$HOME_DIR/.dsh/.credentials.yaml"
PATCH_DEST="$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"
LAUNCH_AGENTS="$HOME_DIR/Library/LaunchAgents"
PROXY="http://127.0.0.1:7897"

say()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }
fail() { echo "  ✗ $*"; exit 1; }

echo "==== dsh-chatgpt-connector 部署 ===="
echo "仓库:   $REPO_DIR"
echo "DSH:    $HARNESS_DIR"
echo ""

# ---------- 1. 依赖检查 ----------
echo "--- 1/5 依赖检查 ---"
[ -d "$HARNESS_DIR" ] || fail "DSH checkout 不存在: ${HARNESS_DIR}（用 DSH_HARNESS_DIR 覆盖）"
ok "DSH checkout: $HARNESS_DIR"

command -v dsh >/dev/null 2>&1 \
  && ok "dsh CLI: $(command -v dsh)" || warn "dsh CLI 不在 PATH（应装到 ~/.local/bin 或让 install 前配置 PATH）"

TUNNEL_CLIENT="$HOME_DIR/.local/bin/tunnel-client"
if [ -x "$TUNNEL_CLIENT" ] || command -v tunnel-client >/dev/null 2>&1; then
  ok "tunnel-client: $("$TUNNEL_CLIENT" --version 2>/dev/null || tunnel-client --version 2>/dev/null)"
else
  warn "tunnel-client 未找到（${TUNNEL_CLIENT}）。请从 OpenAI Platform 下载（创建 Tunnel 时平台提供的 oai-tunnel-client），放到 ~/.local/bin/tunnel-client"
fi

if command -v serena >/dev/null 2>&1; then
  ok "serena: $(command -v serena)"
else
  warn "serena 未找到。安装: uv tool install -p 3.13 serena-agent && serena init"
fi

if [ -x "$NODE_BIN" ]; then
  ok "node: $NODE_BIN ($("$NODE_BIN" --version))"
else
  warn "harness 自带 node 不存在: ${NODE_BIN}（用 HARNESS_NODE_BIN 覆盖；或确认 harness 依赖已装）"
fi

# 代理检查（海外 API 必须走代理；代理不在时仅警告——Clash 可能未开，但脚本仍会装）
if curl -sS --max-time 2 -x "$PROXY" -o /dev/null https://api.openai.com 2>/dev/null; then
  ok "代理可用: ${PROXY}（api.openai.com 可通）"
else
  warn "代理 $PROXY 当前不可用（Clash 未开？）。keepalive/watchdog 会带代理启动，恢复后隧道自动连通"
fi

# ---------- 2. 凭据检查 ----------
echo ""
echo "--- 2/5 凭据检查 ---"
TUNNEL_ID=""; API_KEY=""
if [ -f "$CRED_FILE" ]; then
  TUNNEL_ID=$(grep -E '^CONTROL_PLANE_TUNNEL_ID:' "$CRED_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'\'' \r')
  API_KEY=$(grep -E '^CONTROL_PLANE_API_KEY:' "$CRED_FILE" 2>/dev/null | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'\'' \r')
  [ -n "$TUNNEL_ID" ] && ok "CONTROL_PLANE_TUNNEL_ID 已配置" || warn "CONTROL_PLANE_TUNNEL_ID 缺失（${CRED_FILE}）"
  [ -n "$API_KEY" ] && ok "CONTROL_PLANE_API_KEY 已配置" || warn "CONTROL_PLANE_API_KEY 缺失（${CRED_FILE}）"
  chmod 600 "$CRED_FILE" 2>/dev/null && ok "凭据文件权限 600"
else
  warn "$CRED_FILE 不存在。请创建（参考 config/credentials.example.yaml）填入本机专属 Tunnel ID + API Key"
fi

# 提示：MCP auth token 由 daemon 首次启动自动生成（~/.agent-chatgpt-helm/token），无需手动创建
[ -f "$HOME_DIR/.agent-chatgpt-helm/token" ] && ok "MCP auth token 已存在（daemon 自动管理）" \
  || say "（~/.agent-chatgpt-helm/token 会在 web 首次启动后由 daemon 自动生成，无需手动处理）"

# ---------- 3. 合并 cordis.patch.yml ----------
echo ""
echo "--- 3/5 cordis.patch.yml 合并 ---"
if [ -f "$PATCH_DEST" ]; then
  # 幂等检查：匹配任意缩进位置的 - id: dsh-chatgpt-helm（嵌套/insert 格式也能识别）
  if grep -qE '^\s*- id: dsh-chatgpt-helm' "$PATCH_DEST"; then
    ok "patch 已包含 dsh-chatgpt-helm 段（跳过）"
  else
    echo "" >> "$PATCH_DEST"
    cat "$REPO_DIR/patches/helm-tunnel.patch.yml" >> "$PATCH_DEST"
    ok "已追加 dsh-chatgpt-helm tunnelEnabled:false 补丁到 $PATCH_DEST"
    say "提示：补丁合并后需重启 DSH web 才生效（watchdog 会自动拉起，或手动 kickstart）"
  fi
else
  mkdir -p "$(dirname "$PATCH_DEST")"
  cp "$REPO_DIR/patches/helm-tunnel.patch.yml" "$PATCH_DEST"
  ok "已创建 ${PATCH_DEST}（补丁文件）"
fi

# ---------- 4. 安装 LaunchAgents ----------
echo ""
echo "--- 4/5 LaunchAgent 安装 ---"

# web 双 owner 检测：若已存在管理 DSH web 的 LaunchAgent（如 com.example.dsh-web），
# watchdog 与其并发拉起 web 会 EADDRINUSE。提示用户停用其一（不自动改动用户配置）。
WEB_LA=$(find "$LAUNCH_AGENTS" -maxdepth 1 -name '*.plist' -exec basename {} \; 2>/dev/null | grep -E '^(com\.deepseek\.dsh|.*dsh.*web.*)\.plist$' || true)
if [ -n "$WEB_LA" ]; then
  warn "检测到可能管理 DSH web 的 LaunchAgent：$WEB_LA"
  say "    dsh-web-watchdog 也会拉起 web（3080）。两者并发会端口冲突，"
  say "    请停用其中一个（如 mv ~/Library/LaunchAgents/$WEB_LA ~/Library/LaunchAgents/$WEB_LA.disabled + launchctl bootout gui/$(id -u)/${WEB_LA%.plist}），"
  say "    或确认该 Agent 已停用后继续。"
fi

if [ "${INSTALL_SKIP_SERVICES:-0}" = "1" ]; then
  say "INSTALL_SKIP_SERVICES=1，跳过 launchd 安装"
else
  mkdir -p "$LAUNCH_AGENTS" "$HOME_DIR/.dsh/logs"
  for tpl in com.dsh-connector.mcp-proxy com.dsh-connector.tunnel-client-keepalive com.dsh-connector.dsh-web-watchdog; do
    SRC="$REPO_DIR/launchd/$tpl.plist.tpl"
    DST="$LAUNCH_AGENTS/$tpl.plist"
    sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
        -e "s|__HOME__|$HOME_DIR|g" \
        -e "s|__HARNESS_DIR__|$HARNESS_DIR|g" \
        -e "s|__NODE_BIN__|$NODE_BIN|g" \
        "$SRC" > "$DST"
    # 卸载旧 job（幂等）
    launchctl bootout "gui/$(id -u)/$tpl" 2>/dev/null || true
    # 安装新 job
    if launchctl bootstrap "gui/$(id -u)" "$DST" 2>/dev/null; then
      ok "已安装并启动 $tpl"
    else
      # bootstrap 失败可能是已加载，检查
      if launchctl list | grep -q "$tpl"; then
        ok "$tpl 已在运行（无需重复 bootstrap）"
      else
        warn "$tpl bootstrap 失败，请手动检查: launchctl bootstrap gui/$(id -u) $DST"
      fi
    fi
  done
fi

# ---------- 5. 输出验证指引 ----------
echo ""
echo "--- 5/5 完成 ---"
echo ""
echo "下一步："
echo "  1. 确认 DSH web 已运行（http://127.0.0.1:3080）。若未运行，先启动："
echo "       cd $HARNESS_DIR && $NODE_BIN --import tsx/esm apps/cli/src/bin.ts web --no-open"
echo "  2. 运行验证脚本："
echo "       $REPO_DIR/scripts/verify.sh"
echo "  3. 若 3457/3458 未就绪，等 15-30 秒后重跑（keepalive 会拉起隧道）"
echo "  4. 在 ChatGPT 侧创建连接器（见 docs/connector-creation.md），连接成功后对话里即可看到 19 个 DSH 工具"
echo ""
echo "日志："
echo "  watchdog:   $HOME_DIR/.dsh/logs/dsh-web-watchdog.log"
echo "  keepalive:  $HOME_DIR/.dsh/logs/tunnel-client-keepalive.log"
echo "  隧道:       $HOME_DIR/.dsh/logs/tunnel-client-manual.log"
echo ""
echo "==== 部署检查完成 ===="