# 素材与数据说明

## 代码

本项目代码以 MIT 协议发布，见 `LICENSE`。

## 形象素材

- `Assets/mascot.png`：本仓库自带的**中性占位形象**，原创绘制，随代码以 MIT 发布。
- `Assets/mascot.local.png`：**不随仓库分发**（已在 `.gitignore` 中）。它是从本机 WorkBuddy 安装目录
  导出的官方形象，版权归腾讯 / WorkBuddy 所有，仅供本地个人使用。
  如果你把这张图提交到公开仓库，请自行确认授权。

## 数据

桌宠只读取本机的 `%USERPROFILE%\.workbuddy\workbuddy.db`（SQLite，只读）与
`~/.workbuddy/audit-log/`（只读），不联网、不上传任何数据。
