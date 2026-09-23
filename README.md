# RemoteOps Server Agent 远程运维执行代理

[EN](#remoteops-server-agent) | [中文](#remoteops-server-agent-远程运维执行代理)

A minimal, **zero-dependency, self-boosting** HTTP command agent for Windows, written as a single PowerShell script on `.NET HttpListener`. No installers, no runtime, no outbound connection.

一个极简、**零依赖、可自举热升级** 的 Windows 远程命令执行 Agent：单文件 PowerShell + `.NET HttpListener`。无需安装程序、无需运行时、无外连。

> **Keywords 关键词 / SEO**:
> remote command execution, HTTP agent for Windows, PowerShell HttpListener, zero-dependency agent,
> self-boosting / self-reload live upgrade, remote ops, 远程运维, 远程命令执行 Agent,
> Windows 服务器远程助手, 零依赖, 自举热升级, PowerShell 远程执行

---

## Why it matters / 为什么值得用

- **Single file, zero dependency** — 单文件、零依赖，Windows Server 2012 R2 / PowerShell 4.0+ 即可跑。
- **API-driven** — any AI assistant or script can drive it over HTTP with a simple token header.
- **Self-boosting live upgrade (the key innovation)** — 自举热升级（核心创新）。
  It does not guess your future features; instead it lets you add endpoints by editing the script
  and calling `POST /reload` to relaunch itself with the same port / workdir / password.
  它不预判你未来需要什么功能，而是给你现场加码的方式：编辑脚本 → `POST /file` 覆盖 → `POST /reload` 生效。

---

## 中文说明

### 简介
RemoteOps Server Agent 是一个用纯 PowerShell 编写的 HTTP 命令执行 Agent。它监听一个 TCP 端口，
收到带正确 `X-Agent-Token` 请求头后，可执行命令、读写文件、查进程/服务、打包压缩、查看审计日志等，
并支持通过 `/reload` 热加载新版本代码，是 AI 助手与脚本远程运维 Windows 服务器的理想入口。

### 快速开始
1. 以管理员身份运行 `start-agent.bat`，设置端口与连接密码。
2. 用任意 HTTP 客户端以 `X-Agent-Token: <密码>` 请求头访问。
3. 未带密码或密码错误返回 HTTP 403；`/howto` 不需要密码，返回完整接口说明。

### 接口一览
| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/howto` | 使用说明（免密；支持 json / md / zh） |
| GET | `/health` | 存活探针 / 快速验证密码 |
| GET | `/info` | 系统环境、磁盘、MySQL 服务 |
| POST | `/exec` | 执行单条命令（cmd / powershell） |
| POST | `/script` | 执行多行脚本（原始 body，UTF-8 中文安全） |
| GET | `/process` | 查看进程（可 name 过滤） |
| POST | `/process` | 按 pid / name 杀进程 |
| GET | `/service` | 查看服务（可 name 过滤） |
| POST | `/service` | 启动 / 停止 / 重启服务 |
| GET | `/ls` | 列目录 |
| GET | `/tail` | 读文件末尾 N 行（日志） |
| GET | `/file` | 下载文件 |
| POST | `/file` | 上传文件 |
| GET | `/zip` | 打包文件或目录为 zip 并下载 |
| POST | `/unzip` | 上传 zip 并解压到目录 |
| GET | `/audit` | 操作审计日志 |
| POST | `/stop` | 关闭 agent |
| POST | `/reload` | **自举热升级**：按当前 agent.ps1 以相同参数重启 |

### 自举热升级（Self-extension，核心创新）
本 Agent **不预判**你之后会需要哪些功能，而是支持**按需现场自举**：

1. 想一个新功能；
2. 编辑 `agent.ps1`（在 `Handle-Request` 的 switch 中新增一个 case，调用
   `Send-Json` / `Send-Bytes` / `Send-Text`）；
3. `POST /file` 把改好的脚本上传覆盖到服务器；
4. `POST /reload` 让 Agent 杀掉自己并以相同端口 / 工作目录 / 密码重新拉起 —— 约 2 秒完成。

> 提示：上传前请先在本地验证脚本；`/reload` 会把潜在致命 bug 一起上线。

### 安全
- 鉴权：每次请求带请求头 `X-Agent-Token`；`/howto` 无需密码。
- 可选：`-AllowFrom <IP>` 指定来源 IP 白名单。
- 可选：`-CertThumbprint <thumb>` 启用 HTTPS（需先 `netsh http add sslcert` 预约端口）。
- 该 Agent 以启动它的 Windows 账户权限执行命令，通常是 Administrator，请用完即关（POST /stop 或 stop-agent.bat）。

### 技术要点
- 环境：Windows Server 2012 R2 / PowerShell 4.0+，只需 `.NET HttpListener`。
- `POST /reload` 的启动参数持久化在 `agent.boot.json`（不含 token，token 从 token.txt / 命令行读取）。
- 已知：`/audit` 在 Windows PowerShell 5.1 下若直接对 `Get-Content` 切片数组用 `ConvertTo-Json` 会死锁，
  本项目已改为手工拼接 JSON 规避。

---

## English

### Overview
RemoteOps Server Agent is a pure-PowerShell HTTP command execution agent. It listens on one TCP port and,
once a correct `X-Agent-Token` header is supplied, can run commands, read/write files, query processes/services,
build/extract zips, and read an audit trail. It also supports live self-reload to pick up newly-added features —
an ideal remote-ops entry point for AI assistants and scripts on Windows.

### Quick start
1. Run `start-agent.bat` as Administrator, set the port and connection password.
2. Access with header `X-Agent-Token: <password>` on every request.
3. Missing/wrong password returns HTTP 403; `/howto` needs no password and returns the full API manual.

### Endpoints
| Method | Path | Description |
|--------|------|-------------|
| GET | `/howto` | API manual (no auth; json / md / zh) |
| GET | `/health` | Liveness probe / quick password check |
| GET | `/info` | OS, drives, MySQL services summary |
| POST | `/exec` | Run one command (cmd / powershell) |
| POST | `/script` | Run a multi-line script (raw body, UTF-8 safe) |
| GET | `/process` | List processes (optional name filter) |
| POST | `/process` | Kill process by pid or name |
| GET | `/service` | List services (optional name filter) |
| POST | `/service` | Start / stop / restart a service |
| GET | `/ls` | List a directory |
| GET | `/tail` | Read last N lines of a file (logs) |
| GET | `/file` | Download a file |
| POST | `/file` | Upload a file |
| GET | `/zip` | Zip a file or directory and download |
| POST | `/unzip` | Upload a zip and extract to a directory |
| GET | `/audit` | Activity / audit log |
| POST | `/stop` | Shut the agent down |
| POST | `/reload` | **Self-boost**: relaunch with the current agent.ps1 on disk |

### Self-extension (self-boosting live upgrade — the key innovation)
This agent deliberately does **not** guess your future features. Instead it supports **on-demand live boosting**:

1. Think of a feature.
2. Edit `agent.ps1` — add a case to the routing switch in `Handle-Request`, calling
   `Send-Json` / `Send-Bytes` / `Send-Text`.
3. `POST /file` to upload the updated script over the running copy.
4. `POST /reload` — the agent kills itself and relaunches with the same port / workdir / password (~2s).

> Note: test the edited script locally first; `/reload` will also ship a fatal bug if there is one.

### Security
- Auth by header `X-Agent-Token`; `/howto` is intentionally public.
- Optional `-AllowFrom <IP>` source IP allow-list.
- Optional `-CertThumbprint <thumb>` for HTTPS (reserve the port with `netsh http add sslcert` first).
- The agent runs commands as the Windows account that started it (usually Administrator). Stop it when the job is done.

### Notes
- Requires Windows Server 2012 R2 / PowerShell 4.0+; only `.NET HttpListener`.
- `POST /reload` persists boot params in `agent.boot.json` (token excluded; read from token.txt / command line).
- Known: `/audit` can deadlock on Windows PowerShell 5.1 if you pass a `Get-Content`-sliced string array directly to
  `ConvertTo-Json`; this project builds the JSON manually to avoid it.

---

## License / 许可
MIT