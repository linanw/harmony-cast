# 鸿蒙投屏 · Mac 独立接收端

配合本仓库 `cast-sender` 的「投屏到 Mac」应用使用。平板通过同一局域网直接连接 Mac；运行时无需 Linux、USB、SSH 或开发工具。

## 使用

1. 在 Mac 打开 `~/Applications/Harmony Cast.app`（鸿蒙投屏）。
2. 在平板打开「投屏到 Mac」，自动发现列表会显示附近已开启接收的 Mac。上次连接的 Mac 会优先显示。
3. 点选 Mac，应用自动读取当前地址和连接信息；在系统屏幕共享提示中点「允许」，无需输入 IP 或连接码。
4. 可以返回平板桌面、打开其他应用；结束时在发送端点「停止投屏」，或通过系统录屏提示结束。

全屏可点击「全屏」、双击画面，或按 **Control + Command + F**。全屏隐藏控制栏，保留原始宽高比。按 **Esc**、再次双击画面或使用同一快捷键退出。

点击顶部的「声音：Mac／平板」选择播放位置，也可通过「显示 → 声音切换到 Mac」或 **Shift + Command + M** 切换，全屏下同样有效并显示短暂提示。首次使用默认选择平板，之后记住选择。

选择 Mac 时，先让平板媒体声音静音，收到成功确认后 Mac 才开始播放；切回平板时先停止 Mac 播放并清空待播音频，再恢复平板原来的媒体音量与静音状态。停止投屏、关闭 Mac 接收端或网络中断后会恢复平板；心跳超时保护会先停止 Mac 声音，再解除平板静音。应用意外退出时，恢复信息保存在平板，下次打开应用会重试恢复。不会更改铃声、闹钟、麦克风或其他 Mac 应用的声音。

自动切换需要 **Mac 和平板两端都升级到 0.4.0**。旧发送端仍可传送画面，但 Mac 会保持静音并提示更新。

Mac 重启后会重新广播，平板点选时会刷新地址和连接信息。Mac 的「断开」按钮结束当前连接，随后继续等待新连接。

没有找到 Mac 时，先确认接收端已打开、两端在同一局域网，并允许 macOS 的本地网络/防火墙提示，然后点「重新搜索」。部分访客网络会隔离设备或屏蔽组播，此时可在 Mac 点「连接信息」，在平板展开「手动连接」作为备用。系统录屏授权仍需用户确认。

## 安装与构建

0.4.0 提供带拖拽安装引导的 `Harmony-Cast-0.4.0-macOS-arm64.dmg`。打开后将 Harmony Cast 拖到 Applications；若之前通过安装脚本安装在 `~/Applications`，请覆盖原有应用以避免保留多个副本。平板端安装配套的 0.4.0 HAP。

已在 Apple Silicon MacBook Pro 上构建并安装验证。当前提供 **arm64、macOS 14 及以上**的版本；实际验证环境为 macOS 26.6.2。

```sh
./build.sh
./install.sh
```

构建输出 `dist/Harmony-Cast-macOS-arm64.zip`，包含完整的 ICNS 图标和所有运行资源。编译和签名在临时目录完成，避免云同步目录附加的 Finder 属性破坏签名；安装脚本将已签名压缩包展开到用户的 Applications 目录。

构建只需要 Xcode Command Line Tools。播放器使用系统 AppKit、Network.framework、AVFoundation，没有 ffmpeg/VLC 等运行依赖。应用采用本地 ad-hoc 签名，尚未做 Developer ID 公证。

创建 DMG：

```sh
python3 -m venv /tmp/harmony-dmg-tools
/tmp/harmony-dmg-tools/bin/pip install -r packaging/requirements.txt
DMG_PYTHON=/tmp/harmony-dmg-tools/bin/python ./package.sh
```

DMG 包含应用、Applications 快捷方式和适配 Retina 的安装背景。`dist/SHA256SUMS` 提供文件校验值。图标矢量源文件和生成步骤见 `../branding/README.md`。

## 实现

- HarmonyOS 原生录屏直接输出到 H.264 硬件编码器表面，最长边最多 1920 像素，目标 30 fps、6 Mbps。
- Mac 通过 `AVSampleBufferDisplayLayer` 解码并等比例显示；系统内部声音采用 48 kHz 双声道 PCM，通过 `AVAudioEngine` 播放，不采集麦克风。
- 通过 Bonjour/mDNS `_harmonycast._tcp.local.` 自动发现，TXT 携带协议版本、持久设备 ID 和本次运行的连接码；地址、端口由服务解析取得。平板按设备 ID 去重并记住上次连接，连接前重新解析，支持 IPv4/IPv6 地址。
- TCP 47999。握手是 14 字节 ASCII `HCAST02 ` + 六位连接码（兼容旧发送端 `HCAST01 `），成功回复 `0x01`。随后每帧为 4 字节大端长度、1 字节类型、负载。类型 1 为完整 H.264 Annex B access unit，类型 2 为 s16le PCM。新发送端在录屏启动后发送类型 3、单字节 `01`，表示可联动声音。类型 4 为声音确认：大端 uint32 序号、Mac 出声标志、结果（0 成功，1 失败）。
- Mac → 平板的声音命令为 `A1`、Mac 出声标志和大端 uint32 序号。每 0.75 秒续期，Mac 只接受 0.9 秒内匹配本次切换序号的确认，未确认时不播放。3 秒未获确认先停止 Mac 声音，平板 6 秒未收到命令自动恢复；两端定时检查并处理 EOF。
- 每帧上限 4 MiB，发送缓存上限 8 MiB；缓慢连接会中断并提示重新连接。单次仅接收一个设备。自动连接信息会在同一局域网广播，用于选择接收端与会话匹配，不提供设备身份认证；协议未实现 TLS，适合可信局域网。
- 初版为观看端，不含反向触控、文件传输和画面录制。受保护内容遵循系统录屏限制。音画独立即时播放，尚未实现基于时间戳的精确同步。

## 验证

2026-11-14 在测试设备上完成：

- MatePad Mini → Mac，实际收到 **1920 × 1200** 画面，用户确认画面正常。
- 原生全屏、菜单快捷键进入、Esc 退出，以及全屏视频区域铺满内容区域。
- 平板发送端退到后台后仍持续接收真实画面；已接入录制类型的后台长时任务。
- 120 帧 H.264 测试流与 PCM 传输；渲染器持续报告 rendering。
- 错误连接码、非法长度/类型被拒绝；TCP 分片与拒绝后的重新连接正常。
- 0.2.0：MatePad 自动发现 测试 Mac，重复接口只显示一台设备；Mac 退出后从列表移除，重启后重新出现；点选后自动使用新会话信息连接并渲染 1920 × 1200 真实画面。
- 0.2.0：再次通过原生全屏快捷键、Esc 退出和全屏布局自测。
- 0.3.0：新图标的各尺寸与系统图标加载检查通过；DMG 校验、挂载后应用签名、Applications 链接和 Finder 布局检查通过；Mac/HarmonyOS 均已更新，Mac 启动后正常广播接收服务。
- 0.3.1：AVAudioEngine 离线渲染验证默认静音、开启后真实 PCM 输出、立即停止、恢复时不播放旧音频、重连保留开关；声音按钮、偏好保存、全屏快捷键和提示通过自测。静音时 120 帧 H.264 + PCM 网络回归正常，视频持续渲染。
- 0.4.0：MatePad 静音期间，Mac 收到非零 PCM 并持续渲染 1920 × 1200 画面；用户确认「Mac 有声，平板静音」。Mac→平板→Mac 和断开恢复实测通过，原媒体音量 4 得到恢复。过期/乱序确认、静音失败、心跳超时与立即关闭通过状态测试，原生全屏与声音快捷键回归通过。

全屏自测（运行前关闭已打开的接收端）：

```sh
open -n -W --stdout /tmp/harmony-fullscreen-test.log \
  ~/Applications/'Harmony Cast.app' --args --test-fullscreen
cat /tmp/harmony-fullscreen-test.log
```

可用 `--diagnostics` 输出接收状态、连接码、渲染帧数、声音确认和 PCM 峰值（不保存音频内容）。此选项用于开发测试，正常启动不会输出连接码。网络回归脚本见 `tests/stream_smoke.py`。

音频回归测试在 Mac 使用 AVAudioEngine 离线渲染，检查真实 PCM 输出、默认静音、立即停止、清除旧声音和重连保留开关，不会从扬声器播放测试音：

```sh
xcrun swiftc -swift-version 5 Sources/AudioPlayback.swift tests/audio/main.swift \
  -o /tmp/harmony-audio-test -framework AVFoundation
/tmp/harmony-audio-test
```

全屏自测还会检查声音按钮、偏好保存、全屏声音快捷键和提示，并恢复测试前的声音选择。

声音协商状态测试：

```sh
xcrun swiftc Sources/AudioHandoff.swift tests/handoff/main.swift -o /tmp/harmony-handoff-test
/tmp/harmony-handoff-test
```

`--test-audio-handoff --diagnostics` 用于真机测试：首次收到画面后，第 2、6、9 秒依次选择 Mac、平板、Mac，第 13 秒断开；结合发送端 `CastAudio` 日志验证静音确认和原音量恢复。平时不要带此测试参数启动。

录屏与后台任务实现参考华为官方 [录屏指导](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/avscreencapture-screen-recording-c/) 和 [长时任务指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V13/continuous-task-V13/)。

服务发现接口参考 Apple [NWListener.Service](https://developer.apple.com/documentation/network/nwlistener/service-swift.struct) 和华为 [mDNS 服务发现](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-net-mdns/)。
