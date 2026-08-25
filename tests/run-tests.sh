#!/usr/bin/env bash
# 全部故障注入测试入口
# 用法：从仓库根 `bash tests/run-tests.sh`，或进入 tests/ 后 `bash run-tests.sh`
cd "$(dirname "$0")"

# 前置守卫：本机若在运行 dsh-chatgpt-connector 守护（watchdog/keepalive），
# 测试的 fake 进程/动态端口可能与守护探针交互。套件本身已用隔离模式
# （-test 标记 + 动态端口），此守卫仅提示用户知悉，不阻断。
if pgrep -f 'dsh-web-watchdog\.sh|tunnel-client-keepalive\.sh' >/dev/null 2>&1; then
  echo "提示：检测到本机运行中的 dsh-chatgpt-connector 守护。测试使用隔离模式（-test 标记/动态端口/临时目录），不影响实际运行中的服务。"
fi

TOTAL=0; FAILED=0
for t in test-watchdog-decision.sh test-keepalive.sh test-cleanup.sh test-load.sh test-stall-detection.sh; do
  echo "===== $t ====="
  if bash "$t" > /tmp/helm-test-$$.log 2>&1; then
    grep -E "结果" /tmp/helm-test-$$.log
    TOTAL=$((TOTAL+1))
  else
    echo "✗ $t 失败:"; tail -20 /tmp/helm-test-$$.log
    FAILED=$((FAILED+1))
  fi
done
rm -f /tmp/helm-test-$$.log

# mcp-proxy（升级能力层）node:test 套件
echo "===== test-proxy.mjs (node:test) ====="
if node --test test-proxy.mjs > /tmp/helm-proxy-test-$$.log 2>&1; then
  grep -E '^# (tests|pass|fail)' /tmp/helm-proxy-test-$$.log
  TOTAL=$((TOTAL+1))
else
  echo "✗ test-proxy.mjs 失败:"; tail -20 /tmp/helm-proxy-test-$$.log
  FAILED=$((FAILED+1))
fi
rm -f /tmp/helm-proxy-test-$$.log
echo
if [ "$FAILED" = "0" ]; then echo "全部测试套件通过（$TOTAL 套件）"; exit 0; else echo "有 $FAILED 个测试套件失败"; exit 1; fi
