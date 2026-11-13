# 鸿蒙无线投屏 · Linux

在 Lubuntu、Ubuntu 或 Debian 桌面接收鸿蒙设备控制中心发起的 Miracast 屏幕镜像。合并版在华为分享主界面右侧播放 H.264 视频和 AAC 音频，没有投屏时不占用画面区域；独立客户端使用单独的播放窗口。鸿蒙设备使用系统自带的投屏入口。

## 启动

1. 打开「华为分享与投屏」，主界面提供「无线投屏」状态栏。单独安装的投屏客户端可从应用菜单打开「鸿蒙无线投屏」，或在终端运行 `harmony-cast`。
2. 在「设置」选择支持 Wi-Fi Direct 的投屏网卡，点击「开启投屏」（独立版为「开启接收」）。需要时在系统弹窗中授权。
3. 在鸿蒙设备打开「控制中心 → 无线投屏」，选择电脑窗口中显示的设备名称。
4. 点击全屏按钮，或按 F11 切换全屏、按 Esc 退出全屏。合并版还可以双击画面切换全屏。点击「停止投屏」（独立版为「停止接收」）或关闭窗口，客户端释放无线网卡并恢复先前的 Wi-Fi 连接。

接收期间，所选无线网卡会暂时脱离 NetworkManager，用于 Wi-Fi Direct。如果电脑通过该网卡上网，连接会暂时中断。电脑可以通过有线网卡保持联网。接收开启期间，附近支持 Miracast 的设备可以向电脑发起连接。

## 安装

需要 NetworkManager、wpa_supplicant（启用 Wi-Fi Display）、Python 3/Tk、GStreamer 和 [MiracleCast](https://github.com/albfan/miraclecast)。Ubuntu/Debian 可用以下命令安装运行依赖和构建工具：

```sh
sudo apt install network-manager wpasupplicant iproute2 python3-tk pkexec \
  gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
  gstreamer1.0-plugins-bad gstreamer1.0-libav gstreamer1.0-gtk3 gstreamer1.0-x \
  python3-gi gir1.2-gstreamer-1.0 gir1.2-gst-plugins-base-1.0 gir1.2-gtk-3.0 \
  git build-essential cmake pkg-config libglib2.0-dev libudev-dev libsystemd-dev libreadline-dev
```

安装本项目验证过的 MiracleCast 源码版本：

```sh
git clone https://github.com/albfan/miraclecast.git
cd miraclecast
git checkout 0b7f1f1f6586dc65ff480f3cda5c2170a70aa020
cmake -S . -B build -DBUILD_TESTS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build build
sudo cmake --install build
sudo systemctl reload dbus
```

合并版安装包已经部署桌面入口和接收服务。若单独从源码安装投屏客户端，回到工作区根目录运行：

```sh
./linux-cast/install.sh
harmony-cast --check
harmony-cast
```

使用管理员拥有的安装位置运行网络服务，播放器以桌面用户身份运行。源码调试可运行 `./linux-cast/cast.py`，网络服务仍由安装脚本部署。

## 兼容性和验证

- 支持范围是 Miracast 屏幕镜像。华为 Cast+、DLNA 媒体投送及 HDCP 保护内容未实现。华为对不同协议的说明见[华为支持](https://consumer.huawei.com/cn/support/content/zh-cn16081696/)。
- 已在 Lubuntu 26.04、MediaTek MT7925 网卡与 MatePad Mini 悦读版上验证系统无线投屏。通过 5 GHz Wi-Fi Direct 完成组网、地址分配、RTSP 协商和 1920×1080 真实桌面播放。安装修复后重启接收器，真机重连及画面播放再次通过验证。开启、停止及恢复原 Wi-Fi 已连续通过两轮测试。
- 本地 RTP/MPEG-TS 测试流已通过应用使用的 GStreamer 管线完成 H.264/AAC 解码。

客户端启用 MiracleCast 的 `--use-dev`，接收携带接口名称的组网事件，并在启动完成后清除上游默认的 5 GHz 排除规则，让设备协商可用频段。客户端等待实际扫描状态后才显示「等待投屏」。
