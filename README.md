# Harmony Cast · 鸿蒙投屏

接收 HarmonyOS 设备的屏幕与声音。Mac 版通过配套鸿蒙应用直接连接；Linux 版使用系统 Miracast 无线投屏。

| 组件 | 功能 | 说明 |
| --- | --- | --- |
| [macos-cast](macos-cast/README.md) | Mac 独立接收端 | Apple Silicon、macOS 14+；原生全屏与声音切换 |
| [cast-sender](cast-sender/README.md) | HarmonyOS 发送端「投屏到 Mac」 | API 24+；自动发现 Mac、一键连接、后台投屏 |
| [linux-cast](linux-cast/README.md) | Linux Miracast 接收端 | 从鸿蒙控制中心「无线投屏」直接连接 |
| [branding](branding/README.md) | 共享图标资源 | SVG 源文件、HarmonyOS 分层图和 macOS iconset |

## 下载与安装

[下载 v0.4.0](https://github.com/linanw/harmony-cast/releases/tag/v0.4.0)

- **Mac**：下载 `Harmony-Cast-0.4.0-macOS-arm64.dmg`，打开后将应用拖入 Applications。也提供 ZIP。应用使用本地 ad-hoc 签名，尚未进行 Developer ID 公证。
- **HarmonyOS**：Release 中的 `Harmony-Cast-Sender-0.4.0-unsigned.hap` 需要开发者自行签名。DevEco 签名流程见发送端说明；开发证书、私钥及设备绑定的签名描述文件不上传。
- **Linux**：按 Linux 组件说明安装 MiracleCast 与 GStreamer 依赖，再运行 `./linux-cast/install.sh`。

发布文件附有 `SHA256SUMS`。Mac 和 HarmonyOS 的声音联动要求两端均为 0.4.0。

## Mac 投屏

1. Mac 与平板连接同一局域网，打开 Mac 上的「鸿蒙投屏」。
2. 在平板「投屏到 Mac」中点选自动发现的 Mac，并在系统提示中允许共享屏幕。
3. 返回桌面或打开其他应用，投屏继续运行。
4. 选择「声音：Mac」时，平板先静音，Mac 收到确认后才播放；切回平板或断开时，恢复平板原来的媒体音量与静音状态。

全屏：双击画面、点击全屏按钮或按 **Control + Command + F**；**Esc** 退出。声音切换：**Shift + Command + M**，全屏中同样有效。

Mac 版使用配套应用，不会显示在鸿蒙系统「无线投屏」列表中；Linux 版使用该系统入口。Mac 运行时不需要 Linux 中转、USB 或开发工具。

## 构建与验证

Mac 使用 Xcode Command Line Tools 编译，HarmonyOS 使用 DevEco Studio。各组件 README 包含完整构建与打包步骤。源码不含本地签名凭据、SDK、依赖缓存或编译产物。

已在 MatePad Mini（HarmonyOS 6.1）与 Apple Silicon MacBook Pro 上验证 1920 × 1200 投屏、后台运行、自动发现、全屏以及媒体声音互斥切换。Linux Miracast 已验证 1920 × 1080 系统投屏。Mac 的 PCM 播放、声音确认与超时状态测试位于 `macos-cast/tests/`。

当前为局域网观看客户端，不含反向触控、文件传输或画面录制。Mac 传输尚未启用 TLS，应在可信局域网使用；受保护内容遵循系统录屏限制。
