import Foundation
import Network
import AVFoundation

final class Receiver {
    static let port: UInt16 = 47999
    let code = String(format: "%06d", Int.random(in: 0...999999))
    let name = Host.current().localizedName ?? "Mac"
    private let identifier: String = {
        if let saved = UserDefaults.standard.string(forKey: "receiverID") { return saved }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: "receiverID")
        return created
    }()
    var onStatus: ((String) -> Void)?
    var onSample: ((CMSampleBuffer, CMVideoDimensions) -> Void)?
    var onDisconnect: (() -> Void)?
    var onAudioFallback: ((String) -> Void)?
    private let queue = DispatchQueue(label: "harmony.cast.receiver")
    private let decoder = VideoDecoder()
    private let audio = AudioPlayback()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var generation = UUID()
    private let handoff = AudioHandoff()
    private var audioReady = false
    private var audioAwaitingConfirmation = false
    private var controlProtocol = false
    private var audioTimer: DispatchSourceTimer?
    private var audioMeterAt = ProcessInfo.processInfo.systemUptime
    private var audioPeak = 0

    func start() {
        queue.async { [self] in
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
                self.listener = listener
                audio.onFailure = { [weak self] message in
                    self?.audioFallback("Mac 无法播放声音，已恢复平板 · \(message)")
                }
                var txt = NWTXTRecord()
                txt["v"] = "1"
                txt["id"] = identifier
                txt["code"] = code
                listener.service = NWListener.Service(name: name, type: "_harmonycast._tcp", domain: "local.", txtRecord: txt)
                listener.serviceRegistrationUpdateHandler = { change in
                    if CommandLine.arguments.contains("--diagnostics") {
                        print("DISCOVERY \(change)"); fflush(stdout)
                    }
                }
                decoder.onSample = { [weak self] sample, dimensions in
                    DispatchQueue.main.sync { self?.onSample?(sample, dimensions) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    if case .ready = state { self?.status("在平板「投屏到 Mac」中点选这台 Mac 即可连接") }
                    if case .failed(let error) = state { self?.status("接收服务错误 · \(error.localizedDescription)") }
                    if case .waiting(let error) = state { self?.status("等待本地网络访问 · \(error.localizedDescription)") }
                }
                listener.newConnectionHandler = { [weak self] incoming in self?.accept(incoming) }
                listener.start(queue: queue)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(200))
                timer.setEventHandler { [weak self] in self?.maintainAudioRoute() }
                audioTimer = timer
                timer.resume()
            } catch { status("无法开启接收 · \(error.localizedDescription)") }
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        queue.async {
            self.audio.setEnabled(false)
            self.handoff.select(enabled, now: ProcessInfo.processInfo.systemUptime)
            if self.audioReady {
                self.audioAwaitingConfirmation = true
                self.sendAudioCommand()
                self.status(enabled ? "正在将声音切换到 Mac…" : "正在恢复平板声音…")
            } else if enabled && self.receiving && !self.controlProtocol {
                self.audioFallback("请将平板「投屏到 Mac」更新到 0.4.0，以使用声音自动切换")
            }
        }
    }

    private func sendAudioCommand() {
        guard audioReady, let connection else { return }
        let session = generation
        connection.send(content: handoff.command(now: ProcessInfo.processInfo.systemUptime),
                        completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == session else { return }
            if error != nil { self.finish("声音连接已中断，等待重新连接") }
        })
    }

    private func maintainAudioRoute() {
        guard audioReady else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if handoff.expired(now: now) {
            audioFallback("声音切换未获确认，已关闭 Mac 声音并恢复平板")
        }
        if now - handoff.sentAt >= 0.75 { sendAudioCommand() }
    }

    private func audioFallback(_ message: String) {
        audio.setEnabled(false)
        handoff.select(false, now: ProcessInfo.processInfo.systemUptime)
        sendAudioCommand()
        DispatchQueue.main.async { self.onAudioFallback?(message) }
        status(message)
    }

    private func audioConfirmation(_ body: Data) {
        let wasEnabled = audio.isEnabled
        switch handoff.accept(body, now: ProcessInfo.processInfo.systemUptime) {
        case .ignored: return
        case .rejected:
            if handoff.desired { audioFallback("平板未能完成声音切换，Mac 保持静音") }
            else { status("平板音量恢复失败，请在平板调整音量") }
        case .accepted:
            audio.setEnabled(handoff.confirmed)
            if audioAwaitingConfirmation || wasEnabled != audio.isEnabled {
                status(audio.isEnabled ? "声音在 Mac 播放 · 平板已静音" : "已恢复平板原来的声音")
            }
            audioAwaitingConfirmation = false
            if CommandLine.arguments.contains("--diagnostics") {
                print("AUDIO_ACK serial=\(handoff.serial) mac=\(audio.isEnabled)"); fflush(stdout)
            }
        }
    }

    func disconnect() { queue.async { self.finish("已断开，等待重新连接") } }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.audioTimer?.cancel()
            self.audioTimer = nil
            self.finish("接收已停止")
        }
    }

    private func status(_ text: String) {
        DispatchQueue.main.async { self.onStatus?(text) }
    }

    private func accept(_ incoming: NWConnection) {
        guard connection == nil else { incoming.cancel(); return }
        connection = incoming
        generation = UUID()
        let session = generation
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == session else { return }
            if case .failed(let error) = state { self.finish("连接错误 · \(error.localizedDescription)") }
        }
        incoming.start(queue: queue)
        incoming.receive(minimumIncompleteLength: 14, maximumLength: 14) { [weak self] data, _, _, error in
            guard let self, self.generation == session else { return }
            self.controlProtocol = data == Data("HCAST02 \(self.code)".utf8)
            guard error == nil, self.controlProtocol || data == Data("HCAST01 \(self.code)".utf8) else {
                self.finish("连接码不匹配，请重试")
                return
            }
            self.decoder.reset()
            incoming.send(content: Data([1]), completion: .contentProcessed { [weak self] error in
                guard let self, self.generation == session else { return }
                guard error == nil else { self.finish("连接已关闭"); return }
                self.status("已连接，等待录屏授权")
                if !self.controlProtocol && self.handoff.desired {
                    self.audioFallback("请将平板「投屏到 Mac」更新到 0.4.0，以使用声音自动切换")
                }
                self.readHeader(session)
            })
        }
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == session else { return }
            // A stalled initial handshake must not occupy the only receiver slot.
            if !self.receiving { self.finish("连接超时，请重新连接") }
        }
    }

    private var receiving = false
    private func readHeader(_ session: UUID) {
        receiving = true
        connection?.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self, self.generation == session else { return }
            guard error == nil, let data, data.count == 5 else {
                self.finish("投屏已结束，等待重新连接"); return
            }
            let bytes = [UInt8](data)
            let length = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            let type = bytes[4]
            let valid = ((type == 1 || type == 2) && (1...4_194_304).contains(length)) ||
                (self.controlProtocol && ((type == 3 && length == 1) || (type == 4 && length == 6)))
            guard valid else {
                self.finish("收到无效的媒体数据"); return
            }
            self.connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, self.generation == session else { return }
                guard error == nil, let body, body.count == length else {
                    self.finish("投屏连接已中断"); return
                }
                do {
                    if type == 1 { try self.decoder.consume(body) }
                    else if type == 2 {
                        if self.audioReady && self.handoff.expired(now: ProcessInfo.processInfo.systemUptime) {
                            self.audioFallback("声音切换未获确认，已关闭 Mac 声音并恢复平板")
                        }
                        self.audio.consume(body)
                        self.meterAudio(body)
                    } else if type == 3 {
                        guard body == Data([1]), !self.audioReady else {
                            self.finish("无效的声音协商"); return
                        }
                        self.audioReady = true
                        self.audioAwaitingConfirmation = true
                        self.handoff.select(self.handoff.desired, now: ProcessInfo.processInfo.systemUptime)
                        self.sendAudioCommand()
                    } else { self.audioConfirmation(body) }
                    self.readHeader(session)
                } catch { self.finish("无法解码画面 · \(error)") }
            }
        }
    }

    private func finish(_ message: String) {
        // Silence locally before the sender sees EOF and restores its speaker.
        audio.setEnabled(false)
        audioReady = false
        audioAwaitingConfirmation = false
        controlProtocol = false
        generation = UUID()
        connection?.cancel()
        connection = nil
        receiving = false
        decoder.reset()
        audio.reset()
        DispatchQueue.main.async { self.onDisconnect?() }
        status(message)
    }

    private func meterAudio(_ data: Data) {
        guard CommandLine.arguments.contains("--diagnostics") else { return }
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
                audioPeak = max(audioPeak, abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))))
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - audioMeterAt >= 2 {
            print("AUDIO_PCM peak=\(audioPeak) mac=\(audio.isEnabled)"); fflush(stdout)
            audioPeak = 0
            audioMeterAt = now
        }
    }
}
