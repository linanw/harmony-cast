#!/usr/bin/python3
"""Linux desktop for receiving HarmonyOS screen mirroring over Miracast."""

import argparse
import ipaddress
from pathlib import Path
import queue
import shutil
import socket
import subprocess
import threading
import tkinter as tk
from tkinter import ttk

INSTALLED_SERVICE = Path("/usr/lib/linux-huawei-share/cast/receiver-service")
SERVICE = str(INSTALLED_SERVICE if INSTALLED_SERVICE.is_file()
              else Path("/usr/local/libexec/harmony-cast/receiver-service"))
MEDIA = (
    "rtpjitterbuffer", "rtpmp2tdepay", "tsdemux", "h264parse", "avdec_h264",
    "aacparse", "avdec_aac", "videoscale", "autoaudiosink",
)
PORT = 7236


def wireless_interfaces():
    root = Path("/sys/class/net")
    return sorted(entry.name for entry in root.iterdir()
                  if (entry / "phy80211").exists() or (entry / "wireless").exists()
                  if not entry.name.startswith("p2p-"))


def preflight(embedded=False):
    missing = [name for name in ("nmcli", "miracle-wifid", "miracle-sinkctl",
                                 "miracle-dhcp", "wpa_cli", "gst-inspect-1.0")
               if shutil.which(name) is None]
    if not Path(SERVICE).is_file():
        missing.append("receiver-service（运行 install.sh）")
    if shutil.which("gst-inspect-1.0"):
        plugins = (*MEDIA, "ximagesink" if embedded else "gtksink")
        missing.extend(name for name in plugins if subprocess.run(
            ["gst-inspect-1.0", name], capture_output=True, timeout=4,
        ).returncode)
    if missing:
        raise RuntimeError("缺少组件：" + "、".join(missing))
    import gi
    gi.require_version("Gst", "1.0")
    if embedded:
        gi.require_version("GstVideo", "1.0")
        from gi.repository import Gst, GstVideo
    else:
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gst, Gtk


def privilege_command(use_sudo):
    # Use an existing passwordless/cached sudo grant when present.
    sudo = shutil.which("sudo")
    if sudo and (use_sudo or subprocess.run(
        [sudo, "-n", "-l", "--", SERVICE], capture_output=True, timeout=4,
    ).returncode == 0):
        return [sudo, "-n", "--"]
    return ["pkexec"]


def player_pipeline(address, port=PORT, audio="autoaudiosink", video="gtksink"):
    return " ".join([
        "udpsrc", f"address={address}", f"port={port}",
        "caps=application/x-rtp,media=video,clock-rate=90000,encoding-name=MP2T",
        "!", "rtpjitterbuffer", "latency=100", "!", "rtpmp2tdepay", "!",
        "tsdemux", "name=demux", "demux.", "!", "queue", "!", "h264parse", "!",
        "avdec_h264", "!", "videoconvert", "!", "videoscale", "!", video, "name=screen",
        "demux.", "!", "queue", "!",
        "aacparse", "!", "avdec_aac", "!", "audioconvert", "!", "audioresample",
        "!", audio,
    ])


class ReceiverWindow:
    def __init__(self, root, use_sudo=False, *, check_interface=None, on_close=None,
                 fullscreen=None, controls_parent=None, on_video=None):
        self.root = root
        self.use_sudo = use_sudo
        self.events = queue.SimpleQueue()
        self.receiver = None
        self.player = None
        self.closing = False
        self.stopping = False
        self.failed = False
        self.check_interface = check_interface
        self.on_close = on_close
        self.embedded = fullscreen is not None
        self.fullscreen = fullscreen
        self.on_video = on_video
        self.video_active = False
        self.destroyed = False
        self.poll_after = None

        if not self.embedded:
            root.title("鸿蒙无线投屏")
            root.geometry("550x410")
            root.minsize(480, 360)
            root.protocol("WM_DELETE_WINDOW", self.close)

        interfaces = wireless_interfaces()
        if self.embedded:
            frame = ttk.Frame(controls_parent if controls_parent is not None else root,
                              style="Surface.TFrame", padding=(14, 10))
            frame.pack(fill="x")
            controls = ttk.Frame(frame, style="Surface.TFrame")
            controls.pack(fill="x")
            ttk.Label(controls, text="无线投屏", style="SurfaceName.TLabel").pack(side="left")
            self.state = ttk.Label(controls, style="SurfaceMuted.TLabel")
            self.state.pack(side="left", padx=10)
            self.toggle = ttk.Button(controls, text="开启投屏", width=0, command=self.start)
            self.toggle.pack(side="right")
            ttk.Button(controls, text="详情", width=0, command=self.toggle_log).pack(side="right", padx=(0, 6))
            self.instructions = ttk.Label(frame, wraplength=475, justify="left", style="SurfaceMuted.TLabel")
            frame.bind("<Configure>", lambda event: self.instructions.configure(wraplength=max(240, event.width - 28)))
            self.video_header = ttk.Frame(root, padding=(14, 10), style="Surface.TFrame")
            self.video_header.pack(fill="x")
            ttk.Label(self.video_header, text="鸿蒙投屏", style="SurfaceName.TLabel").pack(side="left")
            self.fullscreen_button = ttk.Button(self.video_header, text="全屏  F11",
                                                 command=lambda: fullscreen(True), state="disabled")
            self.fullscreen_button.pack(side="right")
            self.video = tk.Frame(root, background="black", takefocus=True)
            self.video.pack(fill="both", expand=True)
            self.video.bind("<Button-1>", lambda _event: self.video.focus_set())
        else:
            frame = ttk.Frame(root, padding=22)
            frame.pack(fill="both", expand=True)
            self.instructions = ttk.Label(frame, text="", wraplength=475, justify="left")
            self.instructions.pack(anchor="w", pady=(0, 12))
            frame.bind("<Configure>", lambda event: self.instructions.configure(wraplength=max(240, event.width - 44)))
            controls = ttk.Frame(frame)
            controls.pack(fill="x")
            ttk.Label(controls, text="无线网卡").pack(side="left", padx=(0, 8))
            self.toggle = ttk.Button(controls, text="开启接收", command=self.start)
            self.toggle.pack(side="right")
            self.state = ttk.Label(frame, font=("sans-serif", 12, "bold"))
            self.state.pack(fill="x", pady=(20, 8))

        # In the unified window the interface selector lives in shared settings.
        self.interface = ttk.Combobox(controls, values=interfaces, state="readonly", width=14)
        if not self.embedded:
            self.interface.pack(side="left")
        if interfaces:
            self.interface.current(0)
        if not interfaces:
            self.toggle.configure(state="disabled")
        self.log = tk.Text(frame, width=1, height=3 if self.embedded else 8, wrap="word", state="disabled",
                           relief="flat", padx=10, pady=8)
        if not self.embedded:
            self.log.pack(fill="both", expand=True)
        self.controls = frame
        self.set_state("未开启" if interfaces else "没有无线网卡",
                       "" if self.embedded else "投屏会临时接管所选网卡。若同时使用华为分享，请为分享选择有线或另一块网卡。")
        self.poll_after = root.after(100, self.poll)

    def set_state(self, title, details=""):
        if self.embedded:
            title = {"没有无线网卡": "无无线网卡", "无法开启接收": "开启失败",
                     "正在开启接收": "正在开启", "正在停止接收": "正在停止",
                     "投屏已连接": "已连接", "接收已停止": "已停止"}.get(title, title)
        self.state.configure(text=title)
        self.instructions.configure(text=details)
        if self.embedded:
            self.instructions.pack_forget()
            if details:
                self.instructions.pack(fill="x", pady=(8, 0), before=self.log if self.log.winfo_manager() else None)

    def toggle_log(self):
        if self.log.winfo_manager():
            self.log.pack_forget()
        else:
            self.log.pack(fill="x", pady=(8, 0))

    def set_video_visible(self, visible):
        if not self.embedded or visible == self.video_active:
            return
        self.video_active = visible
        self.fullscreen_button.configure(state="normal" if visible else "disabled")
        if not visible:
            self.fullscreen(False)
        if self.on_video:
            self.on_video(visible)

    def append(self, message):
        self.log.configure(state="normal")
        self.log.insert("end", message.rstrip() + "\n")
        if int(self.log.index("end-1c").split(".")[0]) > 201:
            self.log.delete("1.0", "2.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def start(self):
        try:
            if self.check_interface:
                self.check_interface(self.interface.get())
            preflight(self.embedded)
            prefix = privilege_command(self.use_sudo)
            self.receiver = subprocess.Popen(
                [*prefix, SERVICE, self.interface.get()], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                errors="replace",
            )
        except (ImportError, OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            self.set_state("无法开启接收", str(error))
            return
        self.interface.configure(state="disabled")
        self.toggle.configure(text="停止投屏" if self.embedded else "停止接收", command=self.stop)
        self.set_state("正在开启接收")
        self.stopping = self.failed = False
        threading.Thread(target=self.read_output, args=(self.receiver,), daemon=True).start()

    def read_output(self, receiver):
        with receiver.stdout:
            for line in receiver.stdout:
                self.events.put(line.rstrip())
        self.events.put(receiver.wait())

    def on_event(self, line):
        if not line.startswith("@cast "):
            self.append(line)
            return
        if self.stopping:
            return
        event, _, payload = line[6:].partition(" ")
        name = socket.gethostname()[:32]
        if event == "ready":
            self.set_state("等待投屏", f"在鸿蒙设备上打开「控制中心 → 无线投屏」，选择 {name}。")
        elif event == "peer":
            self.stop_player()
            address = ipaddress.IPv4Address(payload)
            options = []
            if self.embedded:
                options = ["--xid", str(self.video.winfo_id())]
            self.player = subprocess.Popen(
                ["/usr/bin/python3", str(Path(__file__).with_name("player.py")), str(address), *options]
            )
            self.set_state("正在连接", "等待鸿蒙设备发送画面。")
        elif event == "streaming" and self.player is not None:
            self.set_video_visible(True)
            self.set_state("投屏已连接", f"{payload} · F11 切换全屏，Esc 退出。")
        elif event == "disconnected":
            self.stop_player()
            self.set_state("等待投屏", f"可以在鸿蒙设备上重新选择 {name}。")

    def poll(self):
        try:
            while True:
                event = self.events.get_nowait()
                if isinstance(event, int):
                    self.finish(event)
                    if self.closing:
                        return
                else:
                    try:
                        self.on_event(event)
                    except (OSError, ValueError) as error:
                        self.append(str(error))
                        self.failed = True
                        self.stop()
        except queue.Empty:
            pass
        if self.player is not None and self.player.poll() is not None:
            code = self.player.returncode
            self.stop_player()
            if code:
                self.append(f"GStreamer 播放器退出（{code}）。")
                self.failed = True
            self.stop()
        if not self.destroyed:
            self.poll_after = self.root.after(100, self.poll)

    def stop_player(self):
        if self.player is not None:
            if self.player.poll() is None:
                self.player.terminate()
                try:
                    self.player.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self.player.kill()
                    self.player.wait()
            self.player = None
        self.set_video_visible(False)

    def stop(self):
        if self.receiver and not self.stopping:
            self.stopping = True
            self.toggle.configure(state="disabled")
            self.set_state("正在停止接收", "正在释放网卡并恢复 Wi-Fi 连接。")
            self.receiver.stdin.close()
            self.stop_player()

    def finish(self, code):
        self.stop_player()
        self.receiver.stdin.close()
        self.receiver = None
        if self.closing:
            self.destroy()
            return
        self.toggle.configure(state="normal", text="开启投屏" if self.embedded else "开启接收", command=self.start)
        self.interface.configure(state="readonly")
        if code or self.failed:
            self.set_state("接收已停止", "点击「详情」查看日志。" if self.embedded else "请查看下方日志。")
        else:
            self.set_state("未开启", "" if self.embedded else "开启接收后，所选网卡将临时用于 Wi-Fi Direct。")

    def close(self):
        if self.receiver:
            self.closing = True
            self.stop()
        else:
            self.destroy()

    def destroy(self):
        self.stop_player()
        self.destroyed = True
        if self.poll_after is not None:
            self.root.after_cancel(self.poll_after)
        if self.embedded:
            self.controls.destroy()
        self.root.destroy()
        if self.on_close:
            self.on_close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="检查依赖并列出无线网卡")
    parser.add_argument("--sudo", action="store_true", help="使用已有的 sudo 授权")
    options = parser.parse_args()
    if options.check:
        try:
            preflight()
        except (ImportError, OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
            parser.exit(1, f"{error}\n")
        interfaces = wireless_interfaces()
        print("无线网卡：" + ("、".join(interfaces) or "无"))
        return
    root = tk.Tk()
    ReceiverWindow(root, options.sudo)
    root.mainloop()


if __name__ == "__main__":
    main()
