import AppKit
import AVFoundation
import Darwin

final class CastWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        if styleMask.contains(.fullScreen) { toggleFullScreen(sender) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: CastWindow!
    private let video = VideoView(frame: .zero)
    private let receiver = Receiver()
    private let status = NSTextField(labelWithString: "正在开启接收")
    private let connection = NSTextField(labelWithString: "")
    private var receivedPicture = false
    private var sampleCount = 0
    private var handoffTestScheduled = false
    private let diagnostics = CommandLine.arguments.contains("--diagnostics")
    private let fullScreen = NSButton(title: "全屏", target: nil, action: nil)
    private let sound = NSButton(title: "", target: nil, action: nil)
    private var soundMenu: NSMenuItem!
    private var soundEnabled = UserDefaults.standard.bool(forKey: "playReceiverAudio")
    private let soundHUD = NSView()
    private let soundHUDLabel = NSTextField(labelWithString: "")
    private var hideSoundHUD: DispatchWorkItem?
    private var controls: NSStackView!
    private var windowedVideoTop: NSLayoutConstraint!
    private var fullScreenVideoTop: NSLayoutConstraint!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = CastWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable],
                            backing: .buffered, defer: false)
        window.title = "鸿蒙投屏"
        window.minSize = NSSize(width: 640, height: 420)
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.center()
        let root = NSView()
        window.contentView = root
        connection.stringValue = "\(receiver.name) · 自动发现"
        connection.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        connection.isSelectable = true
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        for label in [connection, status] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [connection, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        fullScreen.target = self
        fullScreen.action = #selector(toggleFullScreen)
        fullScreen.bezelStyle = .rounded
        let disconnect = NSButton(title: "断开", target: self, action: #selector(disconnectPeer))
        disconnect.bezelStyle = .rounded
        let details = NSButton(title: "连接信息", target: self, action: #selector(showConnectionInfo))
        details.bezelStyle = .rounded
        sound.target = self
        sound.action = #selector(toggleSound)
        sound.bezelStyle = .rounded
        sound.toolTip = "切换声音播放位置（⇧⌘M）。选择 Mac 时平板自动静音，切回平板或断开时恢复原音量。"
        controls = NSStackView(views: [labels, NSView(), details, sound, disconnect, fullScreen])
        controls.spacing = 12
        for view in [controls!, video] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        windowedVideoTop = video.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12)
        fullScreenVideoTop = video.topAnchor.constraint(equalTo: root.topAnchor)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            controls.heightAnchor.constraint(equalToConstant: 44),
            windowedVideoTop,
            video.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            video.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        soundHUD.translatesAutoresizingMaskIntoConstraints = false
        soundHUD.wantsLayer = true
        soundHUD.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        soundHUD.layer?.cornerRadius = 10
        soundHUDLabel.translatesAutoresizingMaskIntoConstraints = false
        soundHUDLabel.textColor = .white
        soundHUDLabel.font = .systemFont(ofSize: 15, weight: .medium)
        soundHUD.addSubview(soundHUDLabel)
        root.addSubview(soundHUD)
        NSLayoutConstraint.activate([
            soundHUD.centerXAnchor.constraint(equalTo: video.centerXAnchor),
            soundHUD.bottomAnchor.constraint(equalTo: video.bottomAnchor, constant: -28),
            soundHUDLabel.leadingAnchor.constraint(equalTo: soundHUD.leadingAnchor, constant: 18),
            soundHUDLabel.trailingAnchor.constraint(equalTo: soundHUD.trailingAnchor, constant: -18),
            soundHUDLabel.topAnchor.constraint(equalTo: soundHUD.topAnchor, constant: 12),
            soundHUDLabel.bottomAnchor.constraint(equalTo: soundHUD.bottomAnchor, constant: -12)
        ])
        soundHUD.isHidden = true
        video.onToggleFullScreen = { [weak self] in self?.window.toggleFullScreen(nil) }
        receiver.onStatus = { [weak self] text in
            self?.status.stringValue = text
            self?.diagnostic("STATUS \(text)")
        }
        receiver.onDisconnect = { [weak self] in self?.video.reset(); self?.receivedPicture = false }
        receiver.onAudioFallback = { [weak self] message in
            guard let self else { return }
            self.soundEnabled = false
            UserDefaults.standard.set(false, forKey: "playReceiverAudio")
            self.updateSoundControls()
            self.diagnostic("AUDIO_FALLBACK \(message)")
        }
        receiver.onSample = { [weak self] sample, size in
            guard let self else { return }
            if self.video.displayLayer.status == .failed { self.video.displayLayer.flush() }
            self.video.displayLayer.enqueue(sample)
            self.sampleCount += 1
            if self.sampleCount % 30 == 0 {
                self.diagnostic("VIDEO samples=\(self.sampleCount) renderer=\(self.video.displayLayer.status.rawValue) size=\(size.width)x\(size.height)")
            }
            if !self.receivedPicture {
                self.receivedPicture = true
                self.status.stringValue = "正在投屏 · \(size.width) × \(size.height) · 双击画面全屏"
            }
            if CommandLine.arguments.contains("--test-audio-handoff") && !self.handoffTestScheduled {
                self.handoffTestScheduled = true
                for (delay, enabled) in [(2.0, true), (6.0, false), (9.0, true)] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if self.soundEnabled != enabled { self.sound.performClick(nil) }
                        self.diagnostic("HANDOFF_TEST requestedMac=\(enabled)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 13) {
                    self.receiver.disconnect()
                    self.diagnostic("HANDOFF_TEST disconnected; verify tablet restoration")
                }
            }
        }
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        menu.addItem(applicationItem)
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出鸿蒙投屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "显示")
        let item = viewMenu.addItem(withTitle: "切换全屏", action: #selector(toggleFullScreen), keyEquivalent: "f")
        item.keyEquivalentModifierMask = [.control, .command]
        item.target = self
        soundMenu = viewMenu.addItem(withTitle: "声音切换到 Mac", action: #selector(toggleSound), keyEquivalent: "m")
        soundMenu.keyEquivalentModifierMask = [.shift, .command]
        soundMenu.target = self
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        NSApp.mainMenu = menu
        updateSoundControls()
        receiver.setAudioEnabled(soundEnabled)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(video)
        NSApp.activate(ignoringOtherApps: true)
        receiver.start()
        diagnostic("CONNECT code=\(receiver.code) port=\(Receiver.port)")
        if CommandLine.arguments.contains("--test-fullscreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.control, .command], timestamp: 0,
                    windowNumber: self.window.windowNumber, context: nil,
                    characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
                guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
                    print("FULLSCREEN_SHORTCUT_FAILED"); exit(1)
                }
            }
        }
    }

    @objc private func toggleFullScreen() { window.toggleFullScreen(nil) }
    private func updateSoundControls() {
        sound.title = soundEnabled ? "声音：Mac" : "声音：平板"
        sound.image = NSImage(systemSymbolName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                              accessibilityDescription: sound.title)
        sound.state = soundEnabled ? .on : .off
        soundMenu.state = sound.state
        sound.setAccessibilityLabel(sound.title)
    }
    @objc private func toggleSound() {
        soundEnabled.toggle()
        UserDefaults.standard.set(soundEnabled, forKey: "playReceiverAudio")
        receiver.setAudioEnabled(soundEnabled)
        updateSoundControls()
        if window.styleMask.contains(.fullScreen) {
            hideSoundHUD?.cancel()
            soundHUDLabel.stringValue = sound.title
            soundHUD.isHidden = false
            let hide = DispatchWorkItem { [weak self] in self?.soundHUD.isHidden = true }
            hideSoundHUD = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: hide)
        }
    }
    @objc private func showConnectionInfo() {
        let alert = NSAlert()
        alert.messageText = "\(receiver.name)"
        alert.informativeText = "平板会自动发现并连接这台 Mac。\n\n如需手动连接：\n地址：\(Self.addresses().joined(separator: " / "))\n连接码：\(receiver.code)"
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
    private func diagnostic(_ text: String) {
        if diagnostics { print(text); fflush(stdout) }
    }
    @objc private func disconnectPeer() { receiver.disconnect() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { receiver.stop() }
    func windowWillEnterFullScreen(_ notification: Notification) {
        controls.isHidden = true
        windowedVideoTop.isActive = false
        fullScreenVideoTop.isActive = true
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        hideSoundHUD?.cancel()
        soundHUD.isHidden = true
        fullScreenVideoTop.isActive = false
        windowedVideoTop.isActive = true
        controls.isHidden = false
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreen.title = "退出全屏"
        if CommandLine.arguments.contains("--test-fullscreen") {
            window.contentView?.layoutSubtreeIfNeeded()
            guard video.frame.height == window.contentView?.bounds.height else {
                print("FULLSCREEN_LAYOUT_FAILED"); exit(1)
            }
            print("FULLSCREEN_ENTER_OK video fills content")
            testSoundControls()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.window.makeFirstResponder(self.video)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: self.window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53)!
                NSApp.sendEvent(event)
            }
        }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreen.title = "全屏"
        if CommandLine.arguments.contains("--test-fullscreen") { print("FULLSCREEN_EXIT_OK"); NSApp.terminate(nil) }
    }

    private func testSoundControls() {
        let original = soundEnabled
        let saved = UserDefaults.standard.object(forKey: "playReceiverAudio")
        sound.performClick(nil)
        let buttonOK = soundEnabled != original && soundMenu.state == sound.state &&
            UserDefaults.standard.bool(forKey: "playReceiverAudio") == soundEnabled
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift, .command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "M", charactersIgnoringModifiers: "m", isARepeat: false, keyCode: 46)!
        let shortcutOK = NSApp.mainMenu?.performKeyEquivalent(with: event) == true &&
            soundEnabled == original && soundMenu.state == sound.state && !soundHUD.isHidden
        UserDefaults.standard.set(saved, forKey: "playReceiverAudio")
        guard buttonOK && shortcutOK else { print("AUDIO_CONTROLS_FAILED"); exit(1) }
        print("AUDIO_CONTROLS_OK toolbar, preference, fullscreen shortcut and indicator")
    }

    private static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return ["请连接局域网"] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                           socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result.isEmpty ? ["请连接局域网"] : result
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.run()
