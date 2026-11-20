# 脚本版附加组件

Python 运行时来自本机 Codex 配套依赖包，保留 python.exe、pythonw.exe、python312.dll 的原始有效签名，签名主体为 OpenAI OpCo, LLC；并非本项目自签。Python 的许可全文在 runtime/LICENSE.txt。本项目不声称获得签名方的产品背书。

裁剪了标准库的测试、pip、Tk 和第三方包，仅打包标准库 Python 源码；没有修改解释器二进制。配置使用隔离的 python312._pth。SQLite 运行库替换为现有 WbPet 构建中固定的 3.53.4，未修改该 SQLite 二进制，DLL 名称调整为 sqlite3.dll 供 CPython 适配层加载；SQLite 的原有许可与说明继续适用，详见 THIRD-PARTY-NOTICES.md。

无需用户安装 Python 或 .NET SDK，无需给我们自己的 EXE 申请签名。仍需普通用户能写用户目录；系统如果禁止 VBS/PowerShell/某些 DLL，本包不能保证运行。按进程指定 ExecutionPolicy Bypass，不修改系统策略，不申请管理员权限，不修改 Defender、SmartScreen、源目录 ACL 或 SACL，不移除下载来源标记。
