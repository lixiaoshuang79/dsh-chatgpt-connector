#!/usr/bin/env bash
# 全部故障注入测试入口
cd "$(dirname "$0")/tests"
TOTAL=0; FAILED=0
for t in test-watchdog-decision.sh test-keepalive.sh test-cleanup.sh test-load.sh; do
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
echo
if [ "$FAILED" = "0" ]; then echo "全部测试套件通过（$TOTAL/4）"; else echo "有 $FAILED 个测试套件失败"; exit 1; fi
