#!/usr/bin/env bash
# uninstall.sh — dsh-chatgpt-connector 卸载
#
# 移除本套件在本机安装的所有痕迹：
#   1. 停止并移除两个 LaunchAgent（dsh-web-watchdog / tunnel-client-keepalive）
#   2. 删除 ~/Library/LaunchAgents 下的两个 plist
#   3. 从 ~/.dsh/profiles/web/cordis.patch.yml 中精确删除 dsh-chatgpt-helm 补丁段
#   4. （可选，默认不删）凭据 ~/.dsh/.credentials.yaml 中的两行、~/.agent-chatgpt-helm/、日志
#
# 用法：
#   ./scripts/uninstall.sh                  # 标准卸载（保留凭据）
#   ./scripts/uninstall.sh --purge          # 连凭据/token/日志一起删
#
# 说明：--purge 会删除 CONTROL_PLANE_TUNNEL_ID / CONTROL_PLANE_API_KEY 两行
# （若文件还有其他内容则只删这两行，文件保留），并删除 ~/.agent-chatgpt-helm/ 与日志。

set -u
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME"
LAUNCH_AGENTS="$HOME_DIR/Library/LaunchAgents"
PATCH_DEST="$HOME_DIR/.dsh/profiles/web/cordis.patch.yml"
CRED_FILE="$HOME_DIR/.dsh/.credentials.yaml"
PURGE=0
for a in "$@"; do [ "$a" = "--purge" ] && PURGE=1; done

say()  { echo "  $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

echo "==== dsh-chatgpt-connector 卸载 ===="

# 1. 停止并移除 LaunchAgents
for tpl in com.dsh-connector.tunnel-client-keepalive com.dsh-connector.dsh-web-watchdog; do
  PLIST="$LAUNCH_AGENTS/$tpl.plist"
  launchctl bootout "gui/$(id -u)/$tpl" 2>/dev/null && ok "已停止并移除 $tpl" || warn "$tpl 未在运行（或已移除）"
  if [ -f "$PLIST" ]; then
    rm -f "$PLIST" && ok "已删除 $PLIST"
  fi
done

# 2. 从 cordis.patch.yml 精确删除 dsh-chatgpt-helm 补丁段
if [ -f "$PATCH_DEST" ]; then
  if grep -q '^\- id: dsh-chatgpt-helm' "$PATCH_DEST"; then
    # 删除该段（id 行 + 缩进的 config 块）
    python3 - "$PATCH_DEST" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
out = []
i = 0
removed = False
while i < len(lines):
    if re.match(r'^\s*- id: dsh-chatgpt-helm\s*$', lines[i]):
        removed = True
        i += 1
        # 吃掉后续缩进的 config: 块（至少两行，最多到下一个顶层项）
        while i < len(lines):
            if re.match(r'^-\s', lines[i]) or re.match(r'^[A-Za-z]', lines[i]):
                break
            i += 1
        continue
    out.append(lines[i])
    i += 1
if removed:
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print("removed")
else:
    print("notfound")
PYEOF
    if [ $? -eq 0 ] && python3 -c "import sys; print(open('$PATCH_DEST').read().count('dsh-chatgpt-helm'))" 2>/dev/null | grep -q '^0$'; then
      ok "已从 $PATCH_DEST 删除 dsh-chatgpt-helm 补丁段"
    else
      warn "补丁段删除结果异常，请手动检查 $PATCH_DEST"
    fi
  else
    ok "cordis.patch.yml 中无 dsh-chatgpt-helm 段（无需处理）"
  fi
else
  warn "cordis.patch.yml 不存在（无需处理）"
fi

# 3. 凭据与 token（仅 --purge）
if [ "$PURGE" = "1" ]; then
  if [ -f "$CRED_FILE" ]; then
    python3 - "$CRED_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
out = [l for l in lines if not l.startswith(("CONTROL_PLANE_TUNNEL_ID:", "CONTROL_PLANE_API_KEY:"))]
with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
print(f"removed {len(lines)-len(out)} lines")
PYEOF
    ok "已从 $CRED_FILE 删除 CONTROL_PLANE_* 两行（其余内容保留）"
  fi
  rm -rf "$HOME_DIR/.agent-chatgpt-helm" && ok "已删除 ~/.agent-chatgpt-helm/"
  rm -f "$HOME_DIR/.dsh/logs/dsh-web-watchdog.log" "$HOME_DIR/.dsh/logs/tunnel-client-keepalive.log" \
        "$HOME_DIR/.dsh/logs/tunnel-client-manual.log" "$HOME_DIR/.dsh/logs/tunnel-client-keepalive.state" \
        "$HOME_DIR/.dsh/logs/tunnel-client-keepalive.pid" "$HOME_DIR/.dsh/.dsh-web-watchdog.pid" \
        "$HOME_DIR/.dsh/logs/dsh-web-watchdog-launch.log" 2>/dev/null
  ok "已清理日志与状态文件"
else
  say "（凭据/日志已保留；如需彻底清除请加 --purge）"
fi

echo ""
echo "==== 卸载完成 ===="
echo "残留检查："
echo "  launchctl list | grep -E 'dsh-web-watchdog|tunnel-client-keepalive'  （应无输出）"
echo "  ls $LAUNCH_AGENTS | grep -E 'dsh-web-watchdog|tunnel-client-keepalive' （应无输出）"
echo "如需恢复：重新运行 ./scripts/install.sh"
