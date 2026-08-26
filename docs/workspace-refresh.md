# workspace-refresh 补丁说明

**缺陷**：`agent-chatgpt-helm` daemon 的 `code_use_workspace` 用内存中的
ProjectRegistry 校验工作区，该 registry 只在 adapter 建立连接（`onRegister`）时
同步一次 DSH 的 workspaceRegistry，断开时整体移除。之后在 DSH 侧新注册的
工作区对 Serena 代码智能工具永远不可见，必须重启 web 才生效——表现为
`project is not registered/authorized` 拒绝，即使 `workspaces_list` 已能列出。

**修复**（patches/workspace-refresh.mjs，幂等补丁）：
`code_use_workspace` 的 `projects.resolve` 失败时回退到 adapter 实时
`listWorkspaces()`（动态反映 DSH workspaceRegistry，无需重启），匹配到
即激活并顺手 `registerWorkspace` 补进 ProjectRegistry；此后同一路径直接
命中，新增/删除工作区即时生效。

**应用**：
```bash
node patches/workspace-refresh.mjs
# 幂等；应用前自动备份 .bak-workspacerefresh-<ts>；语法校验失败自动回滚
```

**生效**：修改的是插件代码，需重启 DSH web：
```bash
launchctl kickstart -k "gui/$(id -u)/com.dsh-connector.dsh-web-watchdog"
```
（watchdog 拉起的 web 加载新插件代码；插件重装/升级后重跑本脚本即可。）

**验证**：
1. DSH 侧注册新工作区：`POST /api/workspace.create {path: <目录>}`
2. 经 mcp-proxy 调 `code_use_workspace {workspace: <绝对路径>}` → 应返回
   `active_workspace` 与 `serena_url`（修复前抛 `project is not registered/authorized`）
3. 重复调用直接命中（无需再次回退）

**会话可见性说明**：ChatGPT 经 daemon 的 `sessions_list` 直接看到 DSH 全部
持久化会话（默认最新 50 个，limit 可到 100），与 workspace 注册无关；
workspace 注册只影响 Serena `code_*` 工具的可激活范围。
