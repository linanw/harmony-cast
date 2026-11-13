# 投屏到 Mac · HarmonyOS 发送端

独立的原生 HarmonyOS 应用，包名 `me.harmony.cast.sender`。接收端、使用步骤和验证记录见 `../macos-cast/README.md`。

## 构建

使用 DevEco Studio 26.0 SDK，兼容 API 24（当前 MatePad 为 HarmonyOS 6.1）。

```sh
./build.sh           # 编译未签名 HAP
./build.sh --signed  # 使用本机已有签名配置
./build.sh --install # 签名并安装到 hdc 连接的设备
```

可通过 `DEVECO_HOME` 指定 DevEco 安装目录。脚本默认使用 Linux 的 `/opt/devecostudio` 或 macOS 的 `/Applications/DevEco-Studio.app/Contents`。

新设备首次安装需要在 DevEco Studio 中打开此项目，进入 Project Structure → Signing Configs，启用自动签名，并选择已连接的设备。确保 `app.products` 的 `signingConfig` 指向生成的配置。签名配置按开发者与测试设备分别生成。

签名配置保存在本机 `~/.ohos/config/cast-sender-build-profile.json5`，不加入仓库；也可以通过 `HARMONY_CAST_SIGNING_PROFILE` 指定。构建脚本临时使用该配置，退出时恢复公开的无凭据配置。调试 HAP 仅适用于签名描述文件授权的设备，其他设备需要重新签名。

GitHub Release 提供 `Harmony-Cast-Sender-0.4.0-unsigned.hap`，不含开发证书和设备签名描述文件，需要在 DevEco 中配置自己的签名后安装。开发环境可运行 `./build.sh --install` 直接构建、签名并安装。测试用的设备绑定 HAP 保留在本地 `dist/`，不上传仓库。

## 运行行为

打开后自动搜索同一局域网内的 Mac。点选设备即可连接，无需输入地址与连接码；上次连接的设备优先显示。通过持久设备 ID 去重，Mac 下线时移除列表项，点选时重新解析最新地址、端口和会话信息。需要时可展开手动连接作为备用。系统要求用户允许屏幕采集后才开始传输。只申请网络与后台运行权限；不开启麦克风。系统声音通过录屏接口采集。

录制类型后台任务维持投屏，按返回键时移到后台；从系统提示或应用停止投屏会释放采集、编码、网络和后台任务。网络错误后可重新连接。

源码：`entry/src/main/ets/services/MacDiscovery.ets`（自动发现与解析）、`entry/src/main/ets/pages/Index.ets`（设备列表、连接及后台任务）、`entry/src/main/cpp/cast.cpp`（录屏、编码和传输）。

## 声音自动切换

需要配合 Mac 0.4.0。Mac 选择「声音：Mac」后，发送端保存当前媒体音量与静音状态、静音平板，确认成功后 Mac 才播放。选择平板或断开时恢复原状态；录屏音频仍继续传输。铃声、闹钟和麦克风不受影响。

使用公开但已废弃的 `AudioManager.mute` / `setVolume` 媒体接口，已在当前 MatePad 验证可调用；其他系统版本需验证。恢复记录先持久化再静音，恢复成功后清除；意外退出后的下次启动会重试恢复。定时检查在录制后台任务期间持续运行，网络断开或 6 秒没有新控制指令时自动恢复。Mac 的播放确认先于该期限过期，避免网络故障时重复出声。

声音状态协调位于 `entry/src/main/ets/services/AudioOutput.ets`，所有静音与恢复操作串行执行；C++ 单独接收声音控制指令并使用单调时钟检查时效。
