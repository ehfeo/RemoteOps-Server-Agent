# RemoteOps Agent

让 AI 助手（WorkBuddy / Trae / Claude / 任何会发 HTTP 请求的助手）间接操作
Windows Server 2012 R2 —— 服务器上跑一个**零依赖的 PowerShell HTTP 代理**，
助手通过 HTTP 发命令、取回 stdout / stderr / 退出码，等价于远程命令行。

```
  +--------------------+   HTTP :8765    +----------------------------+
  |  AI assistant      | --------------> |  Windows Server 2012 R2    |
  |  (any HTTP client) |   token auth    |  agent.ps1 (SYSTEM)        |
  |                    | <-------------- |  -> cmd.exe / powershell   |
  +--------------------+   JSON result   +----------------------------+
```

不需要在服务器上安装任何东西 —— PowerShell 4.0 + .NET HttpListener 是系统自带的。
所有脚本为**纯 ASCII + CRLF**，兼容 PowerShell 3.0+。

---

## 自说明：把 agent 交给别人也能用

agent 自带一份**免密码的说明书**，任何 AI 助手只要拿到 IP 和端口就能自助上手：

```
GET  http://IP:端口/howto            -> JSON 机器契约（推荐给 AI 读）
GET  http://IP:端口/howto?format=md  -> Markdown 英文版
GET  http://IP:端口/howto?format=md&lang=zh  -> Markdown 中文版（HOWTO.zh.md）
GET  http://IP:端口/   或  /help     -> 同 /howto
```

别人拿到 agent 后的完整流程：

1. 拷贝到他自己的服务器上，双击 `start-agent.bat` 设好密码
2. 告诉他的 AI 助手：IP + 端口（**此时不需要给密码**）
3. AI 访问 `/howto` → 得知这是个命令执行代理、有哪些接口、密码要放在
   `X-Agent-Token` 头里、该怎么向用户索要密码
4. AI 问用户要密码 → `GET /health` 验证 → 开始干活

设计要点：

- **`/howto` 是唯一不需要密码的接口**，这是"陌生 AI 自助接管"的唯一入口，必须留着
- 它**不泄露任何秘密**，也不提供任何执行能力
- `-AllowFrom`（IP 白名单）对 `/howto` **同样生效**；密码限制对它不生效
- 密码错误时 403 响应里带了 `hint` 字段指向 `/howto`，AI 不会卡死
- 说明书正文写死在 `agent.ps1` 里且**必须纯 ASCII**（PowerShell 5.1 及以下按 GBK
  解析无 BOM 的 .ps1），所以 JSON/Markdown 正文是**英文**；
  中文版单独放 `HOWTO.zh.md`，由 agent 以**原始字节**读出返回，绕开编码问题

客户端验证：

```bash
python agent-cli.py --host IP --port 8370 howto                  # 不带密码
python agent-cli.py --host IP --port 8370 howto --format md --lang zh
```

### 启动时自动生成「AI 交接文本」（零键盘输入）

`start-agent.ps1` 启动成功后会**自动探测**本机内网 IP 和公网 IP，套进模板生成一段
可以直接复制粘贴给 AI 的文本，人不用再手打任何东西：

```
================ COPY EVERYTHING BELOW ================
请把下面这段内容复制给你的 AI Agent（一次粘贴即可，它看完就知道该怎么做了）：

请连接 Server Agent：192.168.16.2:8370, 120.48.127.4:8370

然后发送一个 GET 请求到 http://120.48.127.4:8370/howto
（这个接口不需要密码）获取完整的接口说明和使用方法。

接口权限密码是：aaaaa1.

补充：密码要放在每一个请求的 HTTP 头 X-Agent-Token 里。
...
================ COPY EVERYTHING ABOVE ================
```

要点：

- **公网 IP 是"尽力而为"探测**（依次试 `api.ipify.org` / `ifconfig.me` / `icanhazip.com` /
  `myip.ipip.net`，每个 6 秒超时）。服务器没有出网 HTTP 时探测不到，会打印
  `none (no outbound HTTP)` 并只用内网 IP，**绝不影响启动**。
- 模板 `paste-template.zh.txt` 是 UTF-8 中文，由脚本按**文本读入**再替换占位符，
  不经过 PowerShell 字符串字面量（否则无 BOM 的 .ps1 会被按 GBK 解析而崩溃）。
- 模板文件缺失时自动回退到**纯 ASCII 英文版**，保证任何环境都能出东西。
- 同时会写到同目录 `AI-HANDOFF.txt`（UTF-8 BOM，记事本能正常打开），
  方便 RDP 里复制不方便时直接取文件。
- ⚠️ 这段文本**包含明文密码**，别贴到公开场合。

---

## 0. 云服务器必读：有【两道】防火墙

这是最常见的"本机通、外网不通"的根因。两道墙是**串联**的，缺一不可：

```
  外网  ->  [云安全组]  ->  [Windows 防火墙]  ->  你的程序
              ^^^^^^^^^        ^^^^^^^^^^^^
              控制台配置        服务器里配置
              默认拒绝一切      你一般配过
```

判据很明确：

| 从外网测试的现象 | 含义 |
|---|---|
| **Timeout（超时）** | 包在到达服务器之前就被丢了 -> **云安全组没放行**，服务器里怎么配都没用 |
| **Connection refused** | 包到了服务器，但没人监听 -> 程序没启动，或只监听了 127.0.0.1 |

所以部署 agent 时，**云安全组和 Windows 防火墙都要放行端口**。
（百度智能云 BCC：控制台 -> 云服务器 BCC -> 实例 -> 安全组 -> 入站 -> 添加规则）

> 本套脚本里的 `install-agent.ps1` / `start-agent.ps1` 只负责 **Windows 防火墙**那一层。
> 云安全组必须你自己去控制台配，脚本碰不到。

---

## 1. 部署到服务器

把整个 `remote-agent` 文件夹拷到服务器（例如 `C:\RemoteOps\`）。

### 推荐：`start-agent.bat`（不依赖计划任务，立即生效）

右键**以管理员身份运行**。它会交互式问你三件事：

```
Listen port [8765]:              <- 直接回车用 8765
Allow only from IP [empty=any]:  <- 见下方说明
Set connection password (input hidden)   <- 自己设一个，输入不可见
Confirm password (input hidden)          <- 再输一次，防止打错
```

然后自动完成：写入密码 -> 预留 URL -> 开 Windows 防火墙 -> 启动 -> 探测 /health。

跑完会打印：

```
Password   : 你设的密码
Server IPs : 192.168.16.2
Agent is running.
```

**把密码发给我。**

命令行等价写法（适合无人值守 / 远程重启）：

```powershell
start-agent.ps1 -Port 8370 -Password '你设的密码'
start-agent.ps1 -Port 8370 -AskPassword          # 交互式，隐藏输入
```

密码存到 `token.txt`，agent 启动时从那里读。**不通过命令行传给 agent**，
避免出现在进程列表里。

> 不设密码也不会开天窗：脚本会退而生成一个 64 位随机串。

### 关于 `Allow only from IP`

留空 = 任何知道 token 的人都能连。填了 = 只有那个源 IP 能连（双重保险）。

建议：**第一次留空**，先确认能连通；跑通之后再带上你的 IP 重启一次收紧。
因为你的出口 IP 可能是动态的，一开始就限定反而容易连不上。

### 备选：`install-agent.bat`（注册开机自启计划任务）

```
install-agent.bat -AllowFrom 203.0.113.9
```

以 SYSTEM 运行、开机自启。之前在 Server 2012 R2 上 `schtasks` 分支出过问题，
已修复为逐步验证（URL 预留 / 防火墙 / 任务注册 / health 探测各步单独判定）。
若仍失败，直接用 `start-agent.bat`，功能等价，只是重启后不会自动起来。

### 卸载

```
uninstall-agent.bat
```

---

## 2. 安全性（请认真看）

- 这等于**在服务器上开了一个能执行任意命令的 HTTP 端口**。建议：
  - 用 `-AllowFrom` 限定来源 IP；
  - 或只在内网 / VPN 开放；
  - **用完就卸载**，别长期挂在公网。
- Token 在 `token.txt`（64 位十六进制，启动时自动生成），不要外传。
- 所有执行过的命令都记在 `agent.log`。
- 目前是 HTTP 明文，token 在网络上是明文传输。公网裸奔有被嗅探的风险。

---

## 3. 我这端怎么用（agent-cli.py）

需要 Python 3。

```bash
# 建个配置，省得每次带参数
cp agent-config.example.json agent-config.json   # 填 host / port / token

python agent-cli.py health
python agent-cli.py info
python agent-cli.py probe                        # 裸 TCP 探测，判断通不通
python agent-cli.py exec "ipconfig /all"
python agent-cli.py exec "Get-Service" --shell powershell
python agent-cli.py script ./diag-web.ps1
python agent-cli.py tail "C:\path\error.log" --lines 300
python agent-cli.py ls "C:\Program Files"
python agent-cli.py get  "C:\remote\file.txt" -o local.txt
python agent-cli.py put  local.exe "C:\remote\file.exe"
python agent-cli.py stop
```

不带配置也能跑：`python agent-cli.py --host 1.2.3.4 --token xxx exec "dir c:\"`

> 客户端已强制绕过本机 HTTP 代理，否则对内网/公网 IP 的请求会被代理拦截。

---

## 4. HTTP 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活探测 |
| GET | `/info` | 系统 / 磁盘 / 管理员 / MySQL 服务概览 |
| POST | `/exec` | `{"cmd":"...","shell":"cmd\|powershell","timeout":120,"cwd":""}` |
| POST | `/script` | 请求体直接是脚本源码，`?shell=powershell&timeout=300` |
| GET | `/file?path=` | 下载文件（二进制） |
| POST | `/file` | `{"path":"...","encoding":"base64\|utf8","content":"..."}` |
| GET | `/tail?path=&lines=200` | 读文本末尾 N 行 |
| GET | `/ls?path=` | 列目录 |
| POST | `/stop` | 关闭 agent |

鉴权：请求头 `X-Agent-Token: <token>`。

---

## 5. MySQL 部署（8.0 免安装版）

### 背景：为什么不用 Installer

MySQL Installer 5.7/8.0 要求 **.NET Framework 4.5.2+**，而 Server 2012 R2 出厂是
**4.5.1**。不满足时它的行为很坑：**文件照常复制完（看起来装好了），但配置向导不弹出**，
服务也不会创建 —— 就是"装完没反应"的经典症状。

所以走 ZIP 免安装版，完全绕开 Installer 和 .NET 依赖。

### 版本上限（重要）

MySQL 官方自 **2024-01-15 停止为 Windows Server 2012 R2 构建二进制包**。所以不存在
"最新版"，只有最后一个支持的版本：

| 版本 | Server 2012 R2 |
|---|---|
| **8.0.35** | 官方最后一批 |
| 8.0.36+ / 8.4 / 9.x | 不再构建 |

国内镜像（华为云）同步到 **8.0.29** 为最高可用。

### 步骤

1. 装 **VC++ 2015-2022 x64**（MySQL 8.0 需要 `vcruntime140.dll`），重启
2. 下载 `mysql-8.0.29-winx64.zip`，解压到 `C:\Program Files\mysql-8.0.29-winx64`
3. 双击 **`setup-mysql80.bat`**（管理员），输两次 root 密码即可

或命令行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "deploy-mysql80.ps1" ^
  -SkipUnzip -DestDir "C:\Program Files\mysql-8.0.29-winx64" -RootPassword "你的密码"
```

自动完成：预检 -> 定位 mysqld -> 写 my.ini -> `--initialize`（随机 root 密码，
不留空密码窗口）-> 装服务 MySQL80 -> 启动 -> 改密码 -> 验证。

**路径策略（重要）**：如果 basedir 含空格（比如放在 `C:\Program Files\` 下），
脚本会把配置和**数据**都放到无空格路径：

| 项 | 位置 |
|---|---|
| 程序文件（basedir） | `C:\Program Files\mysql-8.0.29-winx64`（你解压的地方，不动） |
| 配置文件 my.ini | `C:\ProgramData\MySQL80\my.ini` |
| 数据目录 datadir | `C:\MySQLData\data` |

原因是 mysqld 的**命令行参数**扛不住带空格的路径（见末尾坑列表），
而 my.ini 内部的路径用正斜杠就没有这个问题。数据放 ProgramData/MySQLData
还顺带避开了 Program Files 的 UAC 保护。

---

## 6. 诊断脚本（离线也能用）

连不上 agent 时，这些脚本可以在服务器上直接双击运行，把生成的报告发我。

| 脚本 | 用途 |
|---|---|
| `run-diag.bat` | MySQL 全量体检：my.ini / datadir / 错误日志 / 服务 / 3306 / 事件日志 |
| `run-diag-web.bat` | 网站外网不通：监听地址 / 防火墙规则 / 本机 HTTP 实测 / 谁占了 80 |
| `run-diag-installer.bat` | Installer 为什么不弹配置向导：.NET 版本 / VC++ / Installer 日志 |

报告生成到桌面，拖进对话即可。

---

## 7. 文件清单

| 文件 | 作用 |
|---|---|
| `agent.ps1` | 代理服务端本体（内含 `/howto` 自说明正文，纯 ASCII 英文） |
| `HOWTO.zh.md` | 自说明中文版，由 `/howto?format=md&lang=zh` 以原始字节返回 |
| `start-agent.ps1` / `.bat` | **立即启动（推荐首选）**，不依赖计划任务，结尾会打印可复制的 AI 交接文本 |
| `paste-template.zh.txt` | 交接文本模板（UTF-8 中文），占位符 `{{URLS}}` `{{HOWTO}}` `{{PASSWORD}}` |
| `AI-HANDOFF.txt` | 启动时按模板生成的成品（运行时产生，含密码，别外传） |
| `strings.zh.txt` | **启动器中文文案表**（UTF-8 BOM，54 条 key=value），改了下次启动生效 |
| `lib-ui.ps1` | 文案加载器，被 `start-agent.ps1` / `watch-agent.ps1` dot-source |
| `watch-agent.ps1` / `.bat` | **活动日志窗口**：实时显示 agent 收到了什么命令、结果如何 |
| `agent.log` | 活动日志本体（运行时产生，超过 4MB 自动保留尾部 400 行） |
| `stop-agent.ps1` / `.bat` | 停止 agent（只匹配命令行指向 `agent.ps1` 的进程，不会误杀别的 PowerShell） |
| `install-agent.ps1` / `.bat` | 安装 + 注册开机自启计划任务 |
| `restart-agent.ps1` | 由旧 agent 自己 detached 拉起，完成"换掉自己" |
| `uninstall-agent.bat` | 卸载 |
| `run-agent-console.bat` | 前台试跑，看实时报错 |
| `agent-cli.py` | 我这端的客户端 |
| `deploy-mysql80.ps1` / `setup-mysql80.bat` | MySQL 8.0 免安装部署 |
| `diag-web.ps1` / `run-diag-web.bat` | 网站可达性诊断 |
| `diag-installer.ps1` / `run-diag-installer.bat` | Installer 取证 |
| `mysql-diag.ps1` / `run-diag.bat` | MySQL 全量诊断 |
| `legacy/` | 已弃用的 MySQL 5.7 修复脚本，仅作存档 |

### 为什么每个操作都有 `.ps1` 和 `.bat` 两份

不是冗余，是**壳 + 引擎**的分工，删掉任何一个都会坏：

| | 角色 | 谁来用 |
|---|---|---|
| `.ps1` | 真正的逻辑 | 我远程调用（走 `/script` 接口）、或被别的脚本引用 |
| `.bat` | 三行胶水：双击入口 + 加 `-ExecutionPolicy Bypass` + 交互提示 + `pause` | 你在服务器上双击 |

- **双击 `.ps1` 在 Server 2012 R2 上默认是用记事本打开，不会执行** —— 这就是必须有 `.bat` 的原因。
- 反过来 `.bat` 本身不含逻辑，删了 `.ps1` 它就报错。

如果只要一个文件：留 `.ps1`，但每次都得手敲
`powershell -NoProfile -ExecutionPolicy Bypass -File xxx.ps1`。

---

## 8. 中文界面

启动器（`.bat` 的提问 + `.ps1` 的每一句输出）都是中文。

**中文文案为什么不直接写在 `.ps1` 里**

无 BOM 的 `.ps1` 在 PowerShell 5.1 及以下按 ANSI/GBK 解析，直接塞中文会让
整个脚本语法崩溃（这个项目早期就踩过：一个"入"字把 `diag-web.ps1` 搞挂）。
所以：

- 文案放在 `strings.zh.txt`（UTF-8 **带 BOM**，记事本可直接编辑）
- `lib-ui.ps1` 用 `ReadAllText(..., UTF8)` 读进来，得到的是正确的 .NET 字符串
- `Write-Host` 按控制台代码页（936/GBK）输出，cmd 正常显示
- **任何一条缺失、或整个文件丢失，都自动回退到内置英文**，不会让脚本挂掉

改措辞只改 `strings.zh.txt` 就行，不用碰脚本。加 `-Lang en` 可强制英文。

---

## 9. 活动日志：看到 AI 在干什么

`start-agent.bat` 启动成功后会**自动弹出一个"活动日志"窗口**（就是
`watch-agent.ps1`）。想手动开就双击 `watch-agent.bat`。

日志长这样：

```
20:25:37 | >> EXEC cmd <- 220.173.103.155 :: echo final-check && whoami
20:25:37 | << EXEC exit=0 83ms out=45B err=0B
20:25:37 |    stdout | final-check win-e7phpvp5icc\administrator
20:25:38 | >> TAIL C:\...\agent.log lines=14 <- 220.173.103.155
```

约定：

| 标记 | 含义 | 窗口里的颜色 |
|---|---|---|
| `>>` | 请求刚到，正在执行 | 青色 |
| `<<` | 执行完毕，带退出码/耗时/输出字节数 | 绿色 |
| `stdout` / `stderr` | 输出前 300 字符的摘要 | 灰 |
| `DENY` / `ERROR` / `FATAL` | 被拒绝或出错 | 红 |

两条设计要点：

1. **日志窗口是独立进程**。关掉它**不会**停止 agent —— 你关控制台窗口的本能
   不应该等于把服务杀掉。这也是 agent 本身仍然隐藏运行的原因。
2. 命令执行中会先出现 `>>`、隔一会儿才出现 `<<`，这中间的间隔就是"正在干什么"。

日志文件 `agent.log` 超过 4MB 会自动保留最后 400 行，不会无限增长。

---

## 已知限制

- 命令默认超时 120 秒，单次最大 900 秒；超时会连同子进程一起 kill。
- 交互式命令（等待 stdin 输入的）不适用，stdin 是直接关掉的。
- 编码已处理：PowerShell 脚本经 `-EncodedCommand` 调用，中文不会乱码。
- Windows Server 2012 R2 本身的扩展支持已于 **2026-10-13** 结束，之后不再有安全补丁。

---

## 排障

| 现象 | 原因 / 处理 |
|---|---|
| `schtasks.exe : 错误: 系统找不到指定的文件` | 任务不存在时的无害报错，新版已不会中断安装。仍报错就用 `start-agent.bat` |
| `添加 URL 保留项失败，错误: 183` | 无害，意思是保留项已存在 |
| `FATAL: cannot listen on http://+:8765/` | URL 没预留成功，需管理员身份 |
| 服务器本机 curl 通，外网不通 | **云安全组没放行**（见第 0 节） |
| 装完 health 探测失败 | 跑 `run-agent-console.bat` 看真实报错 |
| 端口被占 | 换端口：`start-agent.ps1 -Port 9000` |

---

## 开发中踩过的坑（记录备查）

- **PowerShell 里 `H` 是内置别名**（指向 `Get-History`），自定义 `function H()` 会被覆盖。
  函数名要用多字符。
- **`Add 'x' + $y` 在参数模式下 `+` 会被当成独立参数**，输出被截断。必须写成
  `Add ('x' + $y)`。
- **脚本里不能出现任何非 ASCII 字符**。UTF-8 无 BOM 的中文在中文 Windows 的
  PowerShell 里按 GBK 解码，一个汉字（如 `入` = `E5 85 A5`）后紧跟引号 0x27 时，
  `A5 27` 不是合法 GBK 序列 -> 引号被吞 -> 字符串未闭合 -> **整个脚本语法崩溃**，
  且报错位置全在别处，极具误导性。
- **`Expand-Archive` 在 PowerShell 4.0 不存在**（5.0 才加），Server 2012 R2 是 4.0，
  要用 .NET 的 `ZipFile.ExtractToDirectory`。
- **`Set-ItemProperty` 的 `-Type` 参数在 PS 4.0 也没有**。
- **`Stop-Process` 匹配进程时不要写 `-like '*agent.ps1*'`** —— 会匹配到
  `install-agent.ps1` 把自己杀掉。要用 `-match '[\\/]agent\.ps1'` 并排除自身 PID。
- **`$ErrorActionPreference='Stop'` 会把原生命令的 stderr 提升为终止性错误**，
  `schtasks /delete` 在任务不存在时就会因此中断整个安装。原生调用要单独收 `$LASTEXITCODE`。
- **`Start-Process -ArgumentList` 对含空格的参数靠不住**。`mysqld --defaults-file=C:\Program
  Files\...\my.ini` 被 mysqld 读成了 `C:\Program`，报 `Failed to open required defaults
  file`，然后**以退出码 0 退出** —— 脚本还以为初始化成功了。
  对策：含空格的路径不要出现在命令行上（配置和数据改放无空格路径），
  并且**不要只信退出码**（见下一条）。
- **mysqld 初始化失败可能返回退出码 0**。判断是否真的初始化成功，要数 datadir 下
  生成的文件数（正常应有 100+ 个），少于 5 个就是失败。
- **PowerShell 里不要用 `-p$变量` 给 mysql 传密码** —— 会变成 `Access denied`。
  用 `$env:MYSQL_PWD = $pw` 传，或者写字面量 `-p密码`（无空格）。
  交互使用 `mysql -u root -p` 手工输入不受影响。
- **无人值守的脚本里不能用 `Read-Host`**（`-NonInteractive` 下会抛
  `PSInvalidOperationException`）。需要输入就改成参数，或让脚本自己从日志里解析。

  > 反过来同样重要：**凡是靠 `Read-Host` 提问的脚本，调用它的 `.bat` 绝对不能加
  > `-NonInteractive`**。2026-09-23 `start-agent.bat` 就是这么写的，结果密码框永远出不来，
  > 直接 `password cannot be empty` 退出，agent 起不来。现在 `.bat` 已去掉这个开关，
  > `.ps1` 里也加了 `[Environment]::UserInteractive` 预判：非交互时不再崩溃，
  > 而是降级复用 `token.txt` 里的现有密码并黄字警告。
- **启动类脚本中途失败会留下一台连不上的机器**（agent 一挂，远程就彻底断了）。
  所以 `start-agent.bat` 末尾有 `if errorlevel 1` 分支，失败时直接把
  `... -Password "你的密码"` 这条**能立刻粘贴的兜底命令**打印出来。
- **同一文件的多处编辑并发下发会静默丢改**。2026-09-23 给 `agent.ps1` 加活动日志时，
  一次并发改了版本号和 `/exec` 日志两处，工具都回报成功，实际只有版本号那一处落盘，
  `/exec` 仍是旧代码 —— 直到在服务器上看到日志还是旧格式才发现。
  对策：**改完必须确认关键行真的在文件里**（grep / ParseFile），
  不能只看工具返回的 "successfully edited"。
- **给 `.bat` 写中文要存成 GBK，不是 UTF-8**。cmd 按控制台代码页（936）读批处理文件，
  存 UTF-8 会整片乱码。反过来 `.ps1` 必须纯 ASCII，中文放外部 `.txt`。
  同一个目录里两种编码并存是有意为之。
