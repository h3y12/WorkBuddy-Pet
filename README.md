# WorkBuddy 桌宠（WbPet）

把 WorkBuddy 桌宠挂到桌面上：干活时浮动、右上角三个思考点；
任务完成时跳两下、亮绿勾并弹托盘通知；有未读结果时挂琥珀色数字徽标。
气泡里实时显示当前任务标题、上下文占用和已观测到的积分增量。

仓库自带的 `Assets/mascot.png` 是一个中性占位形象。想用 WorkBuddy 官方那只抱笔记本的白猫，
把它导出成 `Assets/mascot.local.png` 放在同一目录即可，构建时会优先使用（该文件已在 `.gitignore` 里，不会进仓库）。

## 数据从哪来

WorkBuddy 把会话状态和用量存在本地 SQLite：`%USERPROFILE%\.workbuddy\workbuddy.db`（WAL 模式）。
采集器**只读**打开（`mode=ro` + `PRAGMA query_only`），不改业务数据、不联网。只读打开失败时直接报告中断，不退回可写连接；路径中的空格、中文和 `#` 会通过文件 URI 正确编码。

| 界面上的东西 | 来源 | 说明 |
|---|---|---|
| 当前任务标题 | `sessions.title` / `custom_title` | 取最近活动的会话 |
| 干活 / 完成 / 出错 | `sessions.status` | `working` / `completed` / `error` |
| 未读数 | `sessions.unread` | 徽标数字，最多显示 9+ |
| 上下文占用 | `session_usage.used` ÷ `size` | WorkBuddy 自己的上下文窗口口径 |
| 今日积分 | `credit_json` 的**增量记账** | 库里没有单条请求时间，只能按轮询增量累加，详见下 |
| 任务完成事件 | `sessions.status` 由 `working` 变 `completed` | 采集器对比上一轮状态得出 |

采集器把结果原子写入 `%LOCALAPPDATA%\WbPet\state.json`（约 0.8 秒一次），桌宠每 350ms 读一次。

### 「待确认」是怎么来的

WorkBuddy 不把待确认状态写进 `workbuddy.db`，但会在 `~/.workbuddy/audit-log/` 里成对落审计事件：

```
<category>.needs-approval   (decision=info)   ← 弹出确认框时
<category>.approved / denied (decision=...)   ← 你点完之后
```

同一个 `toolCallId` 只有前者、没有后者，就是还挂在那里等你点。
采集器增量读当天的主日志 + `spool/audit-spool-*.jsonl`，超过 15 分钟没结果的视为过期（防止进程崩溃留下幽灵）。
**覆盖范围**：走安全审计的确认（文件写入、命令执行等）。MCP 授权、连接器登录这类弹窗不走审计，桌宠看不到。

## 状态与动画

| 状态 | 触发 | 表现 |
|---|---|---|
| 待命 | 没有进行中的任务 | 轻微呼吸起伏，报上次任务与已观测用量 |
| 正在干活 | `status = working` | 浮动更快，右上角三个点依次亮灭 |
| 完成 | `working → completed` | 跳两下、绿勾徽标、托盘气泡（显示 8 秒） |
| 未读 | `unread > 0` 且不在干活 | 琥珀色数字徽标，缓慢浮动 |
| 等你确认 | 审计日志里有未决的 `needs-approval` | 琥珀色 `?` 徽标 +「等你确认：文件名」，另弹托盘气泡 |
| 出错 | `status = error` | 红色 `!` 徽标 |
| 中断 | 采集器读不到库 | 灰字「读数暂时中断」，不会瞎报「WorkBuddy 没开着」 |

## 构建

当前目标框架是 **.NET 10（net10.0-windows）**，构建需要 .NET 10 SDK。SDK 不一定要装到系统目录，设 `DOTNET_ROOT` 指向解压目录即可，`publish.cmd` 会优先用它。
self-contained 版自带 .NET 运行时，目标机器不需要装 Desktop Runtime；framework 版需要 .NET 10 Desktop Runtime x64。采集器需要 Python 3.10+（可用随包携带的 embeddable Python，见下）。

```bat
dotnet build -c Release
publish.cmd framework       :: 输出 dist\framework，目标机器需要 .NET Desktop Runtime
publish.cmd self-contained  :: 输出 dist\self-contained，带 .NET 运行时，首次构建可能需联网还原
```

### 发布包（CI 构建）

`.github/workflows/build.yml` 在 `windows-latest` 上跑 Python 回归、WPF smoke、net10 自包含发布，
再下载官方 embeddable Python 3.13 放进 `python\`，用包内解释器实际执行 `import sqlite3` 校验，最后打包上传 artifact。

包内只有：`WbPet.exe`、`collector.py`、`python\`、许可与说明；不含本机数据库、缓存、任务数据和第三方形象素材。

Windows 10 上必须保留 `<CetCompat>false</CetCompat>`：.NET 10 的 apphost 默认带 CET 标记，
在未打全补丁的 Win10 上启动即崩。自包含只带运行时，不改变操作系统的兼容性要求。

## 跑起来

从发布目录运行 `WbPet.exe`。分发时复制/压缩**整个发布目录**，包含 `collector.py` 和许可文件，不能只发 EXE。
快捷方式可在发布目录运行 `WbPet.exe --shortcut` 创建；移动发布目录后需要重新创建。

两个发布模式都仍需 Python。解释器查找顺序是：`WBPET_PYTHON` 环境变量指定的路径 → EXE 同目录的 `python\pythonw.exe` / `python.exe` → PATH → 常见安装目录。设置了 `WBPET_PYTHON` 却指向不存在文件时不会悄悄改用其他解释器。要制作免安装包，可在 `python\` 放置官方 Windows embeddable Python 完整目录（需要包含 sqlite3 支持），并在干净 Windows 环境验证。self-contained 只解决 .NET，不会自动打包 Python。

```bat
:: 双击即可，采集器会自动拉起（单例端口 51927 防重复）
dist\framework\WbPet.exe

:: 源码运行
dotnet build -c Release
bin\Release\net10.0-windows\WbPet.exe

:: 调试时不想让它跟着 WorkBuddy 退出
dist\framework\WbPet.exe --stay

:: 只跑采集器看输出
python collector.py --once
```

- 左键拖动挪位置，位置记在 `%APPDATA%\WbPet\config.json`
- 右键：收起面板、**设置…**（字号 / 面板不透明度 / 角色大小）、
  启动时拉起 WorkBuddy、总在最前、隐藏到托盘、退出
- 托盘图标：双击显示/隐藏；右键退出
- `WbPet.exe --snapshot out.png`：不开窗口，把五种状态渲染成一张对照图（自检用）
- 状态文件超过 10 秒未更新、标记 stale、数据库不可用或 JSON 解析失败时显示「读数暂时中断」，不继续把旧数据显示为正在工作。
- 采集器启动会限频重试（每 15 秒最多一次），不会重复拉起仍存活的自有采集器；缺脚本或解释器时显示诊断信息。
- 隐藏到托盘时停止持续动画，显示后恢复；遵循系统动画开关，呼吸、浮动和思考点的目标帧率设为 20。

## 生命周期

- **不注册任何开机项、计划任务或 WorkBuddy hook。** 只在双击（或桌面快捷方式）时启动。
- 启动时如果 WorkBuddy 没开，桌宠会自己把它拉起来（右键可关掉这一项）。
  查找顺序：注册表 `App Paths\WorkBuddy.exe` → Program Files → 各固定盘 `Program Files\WorkBuddy`
  → `%LOCALAPPDATA%\Programs\WorkBuddy`。
- 拉起后给 120 秒宽限，避免 WorkBuddy 启动慢被自己判死。
- 运行时每 2 秒查一次 `WorkBuddy.exe`；连续 3 次（约 6 秒）查不到就自己退出——
  这个宽限是为了让 WorkBuddy 升级重启时不至于把桌宠杀掉。
- 为什么不用 `SessionStart` hook 做「随 WorkBuddy 启动」：那个钩子由带控制台的进程执行，
  会话重连一次就弹一个 cmd 窗口，实测会一秒一个、抢焦点，已放弃。

## 工程结构

```
collector.py        采集器：读 workbuddy.db → state.json（无第三方依赖）
WbPet.csproj        net10.0-windows + WPF + WinForms（托盘）
MainWindow.xaml     形象、气泡、徽标、思考点的全部布局
MainWindow.xaml.cs  轮询状态、切姿态、托盘、拖动、生命周期、配置
ShortcutHelper.cs   生成桌面快捷方式（--shortcut）
SnapshotRunner.cs   离屏渲染各状态，交付前肉眼验收
Assets/mascot.png   中性占位形象（官方形象放 mascot.local.png，不进仓库）
Assets/pet.ico      托盘/程序图标（多尺寸）
```

## 已知限制

- **上下文占用**是会话级的，不是账号余额；WorkBuddy 没有公开的「剩余额度」接口。
- **今日积分**不能回溯。`session_usage.credit_json` 是「每个会话的累计消耗」，键是随机 UUID、不含时间戳，
  因此无法算出「今天 0 点以来的真实总量」。现在用的是增量记账：每轮记下各会话累计值，
  今天新增 = 本轮累计 − 上轮累计，累加进 `credits-day.json`，跨天清零。
  **只有桌宠/采集器在跑的时候才记得到**；没开桌宠时产生的用量不会计入当天。
  气泡里显示「已观测到使用 X」——不写「今日」，因为它只统计桌宠看到的那段时间；tooltip 会写明「自 HH:MM 起累计」和「会话累计」。
- `status` 由 WorkBuddy 写入，进程被强杀时可能停在 `working`，桌宠会继续显示「正在干活」。
- **未读**依赖 `sessions.unread` 字段；该字段是否被 WorkBuddy 及时置位，取决于它的内部逻辑，
  桌宠只能如实反映库里有什么。
- 采集器单例靠本地端口 51927 占位，被占用时会静默退出（正常现象）。

## 换形象 / 调大小

形象是单张 PNG。把 WorkBuddy 官方形象导成 `Assets/mascot.local.png`（1080×1038，自带透明通道），
构建时会优先加载；没有就用仓库自带的 `Assets/mascot.png` 占位图。绘制代码不用动。
默认以 129×129 居中摆放。

右键 →「设置…」打开设置窗口，三项都带实时预览：

| 项目 | 范围 | 作用 |
|---|---|---|
| 字号 | 10–18 | 气泡里三行文字一起按比例缩放，气泡宽度随之变化 |
| 面板不透明度 | 20–100% | 只作用于气泡，不影响桌宠 |
| 角色大小 | 40–100% | 只缩放猫和它的画布 |

窗口用 `SizeToContent="WidthAndHeight"`，字号调大后窗口自己会长大，
不会再有「大号时右边被裁掉」的问题；进度条也改成按比例分列，不写死像素。

## 回归验证

以下测试仅使用临时模拟数据库和模拟状态，不需要 WorkBuddy 登录，不写入真实数据库：

```bat
python -m unittest discover -s tests -p test_collector.py -v
dotnet build tests\WbPet.SmokeTests.csproj -c Release -o _verify\smoke
dotnet _verify\smoke\WbPet.SmokeTests.dll
```

Python 测试覆盖只读连接、特殊字符路径、数据库缺失、事件保留、错误事件、积分增量和审批日志；界面检查覆盖过期心跳、stale、坏 JSON、恢复、错误/完成区分。真实 WorkBuddy 未来升级后的字段兼容性，以及跨设备、多显示器、安装分发，仍需单独验收。
