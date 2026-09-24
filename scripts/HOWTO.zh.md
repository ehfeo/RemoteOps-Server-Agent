# RemoteOps Server Agent 使用说明

一个零依赖的 HTTP 代理程序，让 AI 助手能够在这台 Windows 服务器上执行命令。
它只是一个 PowerShell 脚本，只用 .NET 的 HttpListener —— 不需要安装任何东西，
不需要运行时，也不会主动往外连。

> 本文件由 `/howto?format=md&lang=zh` 直接返回。英文机器契约见 `/howto`（JSON）。

---

## 0. 一句话流程（给 AI 助手）

1. 你已经拿到了 IP 和端口，先访问 `http://IP:端口/howto` —— **这个接口不需要密码**。
2. 看返回里的 `auth.required`。如果是 `true`，说明其他所有接口都要密码。
3. **向人类用户索要连接密码**。不要猜、不要爆破，密码无法远程找回或重置。
4. 之后每个请求都带上 HTTP 头：`X-Agent-Token: 密码`。
5. 用 `GET /health` 验证：200 说明密码正确，403 说明密码错误或没带。
6. 然后就可以用 `/exec`、`/script`、`/ls`、`/tail`、`/file` 干活了。
7. 干完活提醒人类关掉 agent（服务器上双击 `stop-agent.bat`，或 `POST /stop`）。

---

## 1. 鉴权

| 项 | 值 |
|---|---|
| 请求头 | `X-Agent-Token` |
| 值 | 启动 agent 时人类设置的连接密码 |
| 免密码接口 | 只有 `/howto`、`/help`、`/` |
| 密码错误 | `HTTP 403` + `{"ok":false,"error":"forbidden"}` |

没有登录步骤、没有 cookie、没有 token 交换 —— 每个请求都直接带密码。

密码是**启动 agent 的那个人**在服务器上设的（`start-agent.bat` 会问两次）。
如果丢了，只能让人在服务器上重启 agent 并重设，**网络侧无法恢复**。

---

## 2. 接口一览

| 方法 | 路径 | 需要密码 | 用途 |
|---|---|---|---|
| GET | `/howto` | 否 | 本说明，也可访问 `/` 和 `/help` |
| GET | `/health` | 是 | 存活探测，也是测密码最快的方式 |
| GET | `/info` | 是 | 环境摘要：系统版本、PS 版本、是否管理员、磁盘、MySQL 服务 |
| POST | `/exec` | 是 | 执行一条命令（主力接口） |
| POST | `/script` | 是 | 执行多行脚本，**请求体就是脚本原文** |
| GET | `/ls` | 是 | 列目录 |
| GET | `/tail` | 是 | 读文本文件末尾 N 行（看日志） |
| GET | `/file` | 是 | 下载文件（原始字节） |
| POST | `/file` | 是 | 上传文件 |
| POST | `/stop` | 是 | 关闭 agent |

### POST /exec

```json
{
  "cmd": "ipconfig /all",
  "shell": "cmd",
  "timeout": 120,
  "cwd": "C:\\"
}
```

- `shell`：`cmd`（默认）或 `powershell`
- `timeout`：默认 120 秒，硬上限 900 秒
- 返回：`{"ok":true,"exitCode":0,"stdout":"...","stderr":"...","timedOut":false,"durationMs":123,"shell":"cmd"}`

### POST /script

请求体直接是脚本内容，用查询参数控制：`?shell=powershell&timeout=300`

### GET /ls?path=C:\目录  →  `{"ok":true,"path":"...","items":[...]}`

### GET /tail?path=C:\x\y.log&lines=200  →  `{"ok":true,"totalLines":1234,"content":"..."}`

### POST /file（上传）

```json
{"path":"C:\\x\\y.txt","encoding":"base64","content":"..."}
```

---

## 3. 规则和坑（重要）

- **`/exec` 的命令会被写成临时 .bat 再用 `cmd /c` 跑**，所以是批处理语法：
  `for` 循环变量必须写 `%%i`，写 `%i` 会静默失败。
- `/exec` 默认 shell 是 `cmd`，要用 PowerShell 得显式传 `{"shell":"powershell"}`。
- **stdin 一上来就关闭**：不要发交互式命令，不要用 `Read-Host`、`pause`。
- 装软件、初始化数据库这类长任务，**显式把 timeout 传大**，别让它走超时分支。
- `exitCode` 会透传，但部分 Windows 工具不可靠（比如 mysqld 初始化失败也可能返回 0）。
  判断成败要看**实际效果**（例如数一下 datadir 生成了多少文件），不能只信退出码。
- 原生命令行对**带空格的路径**很脆弱，例如
  `mysqld --defaults-file=C:\Program Files\...` 会被截断成 `C:\Program`。
  这类工具尽量用无空格路径。
- 文本统一 UTF-8，`/exec` 和 `/script` 路径上的中文是安全的。
  （但直接放在磁盘上双击运行的 `.ps1` 在 PowerShell 5.1 及以下会按 GBK 解码，
  那种文件必须纯 ASCII；`.bat` 必须用 CRLF。）
- agent 以**启动它的 Windows 账号**执行命令，通常是 Administrator。
  这是一个**远程命令执行端口**，不用时请关掉。

---

## 4. 最小客户端

```bash
# 免密码读说明
curl http://IP:端口/howto

# 带密码探测
curl -H "X-Agent-Token: 密码" http://IP:端口/health

# 执行命令
curl -H "X-Agent-Token: 密码" -H "Content-Type: application/json" \
     -d "{\"cmd\":\"ipconfig\",\"shell\":\"cmd\",\"timeout\":60}" \
     http://IP:端口/exec

# 上传执行脚本
curl -H "X-Agent-Token: 密码" --data-binary @script.ps1 \
     "http://IP:端口/script?shell=powershell&timeout=300"
```

```python
import json, urllib.request

BASE = "http://IP:端口"
PWD  = "密码"

def call(path, body=None, timeout=120):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data,
                                 method="POST" if data else "GET")
    req.add_header("X-Agent-Token", PWD)
    if data:
        req.add_header("Content-Type", "application/json")
    return json.load(urllib.request.urlopen(req, timeout=timeout))

print(call("/health"))
print(call("/exec", {"cmd": "hostname", "shell": "cmd"}))
```

> 注意：如果本机配了 HTTP 代理，`urllib` 会走代理导致连不上。
> 用 `urllib.request.build_opener(urllib.request.ProxyHandler({}))` 绕过。

---

## 5. 连不上怎么排查

| 现象 | 含义 |
|---|---|
| **超时（Timeout）** | 包根本没到服务器 —— 云安全组或 Windows 防火墙没放行端口 |
| **连接被拒（Refused）** | 端口通但没程序监听 —— agent 没启动 / 被关了 |
| `HTTP 403 forbidden` | 密码没带或不对 |
| `HTTP 404` | 接口路径写错了 |
| `HTTP 500` | agent 自身抛异常，错误详情在 JSON 的 `error` 字段里 |

云服务器有**两道串联防火墙**：云厂商安全组（默认拒绝一切入站）+ Windows 防火墙。
两层都要放行，端口才可能通。

---

## 6. 给人类操作员

- 启动：双击 `start-agent.bat`（管理员）→ 填端口 → 来源 IP 留空回车 → 输两次密码
- 停止：双击 `stop-agent.bat`（管理员）
- 开机自启：`install-agent.bat`（注册计划任务）
- 卸载：`uninstall-agent.bat`
- 启动后屏幕会显示密码，**把它交给你的 AI 助手**
- 用完记得停掉

---

*本文件由 agent 自身提供，无需密码即可读取。*
