<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  tunnel-client-keepalive LaunchAgent 模板
  由 install.sh 自动替换占位符后安装到 ~/Library/LaunchAgents/：
    __REPO_DIR__  → 本仓库在本机的绝对路径
    __HOME__      → 本机主目录
  占位符出现在 Key 值内部时用 __HOME_STR__（本模板未用到，保留说明）。
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dsh-connector.tunnel-client-keepalive</string>

    <!-- 每 15s 检查 tunnel-client 健康 + helm daemon(3457) upstream 健康，
         异常时带正确凭据/代理重新拉起。单实例由脚本 PID 锁保证。 -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__REPO_DIR__/scripts/tunnel-client-keepalive.sh</string>
    </array>

    <!-- 登录后立即跑一次 -->
    <key>RunAtLoad</key>
    <true/>

    <!-- 脚本进程若意外退出，launchd 自动拉起 -->
    <key>KeepAlive</key>
    <true/>

    <!-- 崩溃后重启的最小间隔 -->
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <!-- 注入 DSH checkout 路径（watchdog 用；keepalive 不用但保留一致性） -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>DSH_HARNESS_DIR</key>
        <string>__HARNESS_DIR__</string>
        <!-- 链路：tunnel → mcp-proxy(3461) → helm daemon(3457)。
             HELM_MCP_PORT=tunnel 的 server-url 端口（代理）；
             HELM_UPSTREAM_PORT=健康探针实际探的 daemon 端口。
             想临时绕过代理：把 HELM_MCP_PORT 改回 3457 并重启 keepalive。 -->
        <key>HELM_MCP_PORT</key>
        <string>3461</string>
        <key>HELM_UPSTREAM_PORT</key>
        <string>3457</string>
        <key>HTTPS_PROXY</key>
        <string>http://127.0.0.1:7897</string>
        <key>NO_PROXY</key>
        <string>127.0.0.1,localhost</string>
    </dict>

    <key>StandardOutPath</key>
    <string>__HOME__/.dsh/logs/tunnel-client-keepalive.out</string>
    <key>StandardErrorPath</key>
    <string>__HOME__/.dsh/logs/tunnel-client-keepalive.err</string>
</dict>
</plist>