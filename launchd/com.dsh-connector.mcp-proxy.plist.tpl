<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!--
  mcp-proxy LaunchAgent 模板
  由 install.sh 自动替换占位符后安装到 ~/Library/LaunchAgents/：
    __REPO_DIR__  → 本仓库在本机的绝对路径
    __HOME__      → 本机主目录
    __NODE_BIN__  → Node 可执行（默认 harness 自带 node22）
  职责：在 tunnel 与 helm daemon 之间跑本地 MCP 代理（127.0.0.1:3461/mcp），
  提供会话摘要瘦身 / steer 插队 / 响应守卫（升级能力，见 mcp-proxy/server.mjs）。
  daemon 不可达时代理仍存活（调用时返回结构化错误），由 keepalive 探针兜底。
-->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dsh-connector.mcp-proxy</string>

    <key>ProgramArguments</key>
    <array>
        <string>__NODE_BIN__</string>
        <string>__REPO_DIR__/mcp-proxy/server.mjs</string>
        <string>--port</string>
        <string>3461</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>EnvironmentVariables</key>
    <dict>
        <key>NO_PROXY</key>
        <string>127.0.0.1,localhost</string>
    </dict>

    <key>StandardOutPath</key>
    <string>__HOME__/.dsh/logs/mcp-proxy.out</string>
    <key>StandardErrorPath</key>
    <string>__HOME__/.dsh/logs/mcp-proxy.err</string>
</dict>
</plist>
