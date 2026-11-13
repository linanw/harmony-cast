# 鸿蒙投屏图标

两端共享「屏幕 + 无线波纹」符号和蓝青渐变背景。图形使用可编辑 SVG 绘制，不含文字，在小尺寸下保持辨识度。

- `background.svg`：全幅不透明背景。
- `foreground.svg`：透明前景，屏幕轮廓和无线波纹。
- `render_icons.py`：生成 HarmonyOS 的 1024 × 1024 分层图、启动图和 macOS 的 16–1024 像素 iconset。
- macOS 的系统圆角、光照等外观由系统读取 ICNS 后呈现；HarmonyOS 的背景不预裁切圆角，由系统遮罩处理。

重新生成（Python 3.10 及以上）：

```sh
python3 -m venv /tmp/harmony-icons
/tmp/harmony-icons/bin/pip install -r branding/requirements.txt
/tmp/harmony-icons/bin/python branding/render_icons.py
```

构建 Mac 时通过系统 `iconutil` 将 iconset 编译到应用的 `Contents/Resources/HarmonyCast.icns`。图标生成只影响资源，不改变投屏协议和应用权限。
