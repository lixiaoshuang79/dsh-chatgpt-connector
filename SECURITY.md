# Security Policy

## 威胁模型（Threat Model）

本套件在本机（`127.0.0.1`）暴露三个 HTTP 端点，并通过 OpenAI Secure MCP Tunnel 向 ChatGPT 暴露一个 MCP 服务端：

| 端点 | 端口 | 认证 | 谁能访问 |
|---|---|---|---|
| DSH web UI | 3080 | 无（loopback-only） | 本机任意用户 |
| helm daemon MCP | 3457 `/mcp` | Bearer token（`~/.agent-chatgpt-helm/token`，0600） | 本机持 token 者 + ChatGPT（经隧道） |
| helm daemon healthz | 3457 `/healthz` | 无（loopback-only） | 本机任意用户 |
| tunnel-client healthz | 3458 | 无（loopback-only） | 本机任意用户 |

**关键风险**：ChatGPT 侧的 connector 若配置为 **No Auth**，任何知道/猜出 tunnel_id 的人都可能通过该 tunnel 调用你的 MCP 工具（包括 `sessions_prompt` 等可在本机执行代码的能力）。因此：

- 连接器只 **Add to ChatGPT** 到你自己的账号，不要分享到团队/公共空间；
- tunnel_id 与 API key 视为机密（等价于本机 shell 权限）；
- 一个 tunnel_id 只在一台机器运行一个 tunnel-client。

## 现状防护

- 所有服务绑定 `127.0.0.1`，不对外网暴露任何端口；
- MCP 调用需要 Bearer token（daemon 首启自动生成，32 字节，0600）；
- 控制面凭据存 `~/.dsh/.credentials.yaml`（install.sh 会 `chmod 600`），模板入仓库、真实值不入库（`.gitignore` 覆盖）；
- 守护脚本由 launchd 用户域运行（无 root 权限）；
- 日志不打印凭据值（只打印缺失/存在状态）。

## 密钥处理

| 密钥 | 位置 | 权限 |
|---|---|---|
| CONTROL_PLANE_TUNNEL_ID / API_KEY | `~/.dsh/.credentials.yaml` | 0600，gitignore |
| MCP Bearer token | `~/.agent-chatgpt-helm/token` | 0600，daemon 自动生成 |

禁止把上述任何值提交到 git（包括截图、日志、示例文件）。若怀疑泄露：在 OpenAI Platform 撤销/重建 API key 与 tunnel，并删除/重建 connector。

## 报告漏洞

本项目用 GitHub Security Advisory 接收漏洞报告（Private 提交，无 SLA 承诺）：

- 打开 [Security → Report a vulnerability](https://github.com/lixiaoshuang79/dsh-chatgpt-connector/security/advisories/new)
- 或发 GitHub Issue 并标注 `[security]`

报告内容建议包含：影响版本、复现步骤、预期行为 vs 实际行为。
