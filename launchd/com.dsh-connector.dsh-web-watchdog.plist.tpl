<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  dsh-web-watchdog LaunchAgent 模板
  由 install.sh 自动替换占位符后安装到 ~/Library/LaunchAgents/：
    __REPO_DIR__  → 本仓库在本机的绝对路径
    __HOME__      → 本机主目录
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dsh-connector.dsh-web-watchdog</string>

    <!-- 常驻循环每 N 秒检查 3080(web)+3457(MCP) 双健康，
         连续多次双不健康才受控重启；单实例由脚本 PID 锁保证。
         注意：KeepAlive 常驻（无 StartInterval），脚本内部自带 sleep 循环。 -->
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>__REPO_DIR__/scripts/dsh-web-watchdog.sh</string>
    </array>

    <!-- 登录后立即跑一次 -->
    <key>RunAtLoad</key>
    <true/>

    <!-- 脚本进程若意外退出，launchd 10 秒后自动拉起 -->
    <key>KeepAlive</key>
    <true/>

    <!-- 崩溃后重启的最小间隔 -->
    <key>ThrottleInterval</key>
    <integer>10</integer>

    <!-- 注入 DSH checkout 路径与代理（watchdog 用 DSH_HARNESS_DIR 拉起 web） -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>DSH_HARNESS_DIR</key>
        <string>__HARNESS_DIR__</string>
        <key>HTTPS_PROXY</key>
        <string>http://127.0.0.1:7897</string>
        <key>HTTP_PROXY</key>
        <string>http://127.0.0.1:7897</string>
        <key>NO_PROXY</key>
        <string>127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/8</string>
    </dict>

    <key>StandardOutPath</key>
    <string>__HOME__/.dsh/logs/dsh-web-watchdog.out.log</string>
    <key>StandardErrorPath</key>
    <string>__HOME__/.dsh/logs/dsh-web-watchdog.err.log</string>
</dict>
</plist>