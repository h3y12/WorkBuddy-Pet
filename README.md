# WorkBuddy 桌宠：脚本版 0.3.1

0.3.1 修复了进度条比例被取整的问题（26.3% 空条、56% 满条），同时修复面板透明度和角色缩放的同类问题。数字用量的采集与计算方式不变。更新时退出旧桌宠，从新完整包的 Start.vbs 启动一次；托盘版本应显示 0.3.1-script。

当前主分支使用 Windows PowerShell 5.1 / WPF 界面和 Python 后台采集。之前的 C#/.NET 实现保留在 Git 提交历史中。

## 使用

1. 先从托盘退出旧版桌宠。
2. 完整解压 ZIP，双击 Start.vbs。系统禁用 VBS 时可用 Start.cmd。
3. 首次会复制到当前用户 LocalAppData/Programs/WbPetScript/0.3.1，并创建“WorkBuddy 桌宠（脚本版）”桌面快捷方式。以后从这个快捷方式启动。

不需要安装 Python、.NET SDK 或运行时，不需要购买签名，不申请管理员权限。自己的界面和采集代码是可阅读的 ps1/py 文件，没有生成自己的 WbPet.exe。随包的 Python 解释器保留供应方签名；SQLite 版本固定为 3.53.4。

功能：现有形象和气泡、任务状态/用量/积分、完成和待确认提醒、缺少 unread 字段兼容、拖动、字号/角色大小/面板透明度、总在最前、显示隐藏与托盘、自动查找启动 WorkBuddy、诊断 ZIP。隐藏时停止动画。普通配置和积分记录沿用原 WbPet 数据目录。WorkBuddy 已运行后关闭时，桌宠会在启动宽限期过后跟随退出；未打开 WorkBuddy 时会显示等待。右键可关闭自动启动 WorkBuddy。

脚本版不等于 Windows 免检版。系统策略仍可能禁止脚本或 DLL；未知环境的 SmartScreen/Smart App Control 提示无法保证全部消失。目标电脑需实际验证，不能把本机测试当成跨机认证。不要为此全局关闭防护。

代码不联网、不使用 WorkBuddy 登录凭据，只读 WorkBuddy 本地数据库与审计日志。诊断 ZIP 不包含会话正文或数据库副本。第一次启动会读取自己的配置；配置保存失败会记录为错误，不修改对方数据库。

完整验证记录见 VERIFY.md。原始源码位于 app/ 和 Launch.ps1。此包优先为当前用户的自用场景验证；公开分发时请遵循 NOTICE.md 的形象许可，并使用占位图。

## 开发与打包

仓库随带应用局部 Python 运行时。直接下载并完整解压源代码即可运行，无需在系统安装 Python 或 .NET SDK。公开仓库与默认发布包只提供中性占位图；私人形象 `app/Assets/mascot.local.png` 不提交。

```bat
runtime\python.exe -I -S -m unittest discover -s tests -p test_*.py -v
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File tests\Test-Ui.ps1
runtime\python.exe -I -S tools\package.py
```

打包会生成 SHA256 清单和完整 ZIP。私有形象默认排除；仅个人打包时可显式增加 `--include-local-artwork`，该个人 ZIP 不应上传到公开仓库。

修改代码后，运行打包命令刷新 MANIFEST.json；启动器会拒绝校验不匹配的源文件。随后退出旧桌宠，从 Start.vbs 重新启动以部署新版。Make-Shortcut.ps1 是可选的原地运行入口，直接指向当前目录。

GitHub Actions 使用同一套随包运行时执行测试，再产出公开 ZIP 供下载。项目不包含本机 WorkBuddy 数据库、账号数据或运行日志。
