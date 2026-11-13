#include <napi/native_api.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avformat.h>
#include <native_window/external_window.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netdb.h>
#include <memory>
#include <cerrno>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <atomic>
#include <condition_variable>
#include <chrono>
#include <cstring>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
class Sender {
public:
    std::mutex lifecycle;
    std::atomic<bool> starting{false};
    std::atomic<bool> running{false};
    std::atomic<int> socket{-1};
    OH_AVCodec *encoder = nullptr;
    OH_AVScreenCapture *capture = nullptr;
    OHNativeWindow *surface = nullptr;
    std::thread writer;
    std::thread reader;
    std::atomic<bool> captureStarted{false};
    uint32_t audioSerial = 0;
    bool audioOnMac = false;
    std::chrono::steady_clock::time_point lastAudioCommand{};
    std::mutex mutex;
    std::condition_variable wake;
    std::deque<std::vector<uint8_t>> packets;
    size_t pendingBytes = 0;
    std::string message = "未连接";

    void state(const std::string &value) {
        std::lock_guard<std::mutex> lock(mutex);
        message = value;
    }
    void fail(const std::string &value) {
        state(value);
        running = false;
        int fd = socket.load();
        if (fd >= 0) shutdown(fd, SHUT_RDWR);
        wake.notify_all();
    }
    void enqueue(uint8_t type, const uint8_t *data, size_t size) {
        if (!running || !size) return;
        std::unique_lock<std::mutex> lock(mutex);
        if (size > 4 * 1024 * 1024 || pendingBytes + size > 8 * 1024 * 1024) {
            lock.unlock();
            fail("网络过慢，请停止后重新连接");
            return;
        }
        std::vector<uint8_t> packet(size + 5);
        uint32_t length = htonl(static_cast<uint32_t>(size));
        memcpy(packet.data(), &length, 4);
        packet[4] = type;
        memcpy(packet.data() + 5, data, size);
        pendingBytes += packet.size();
        packets.emplace_back(std::move(packet));
        wake.notify_one();
    }
    bool sendAll(const uint8_t *bytes, size_t size) {
        while (size) {
            ssize_t count = send(socket.load(), bytes, size, MSG_NOSIGNAL);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) return false;
            bytes += count;
            size -= count;
        }
        return true;
    }
    void writeLoop() {
        while (running) {
            std::vector<uint8_t> packet;
            {
                std::unique_lock<std::mutex> lock(mutex);
                wake.wait(lock, [this] { return !running || !packets.empty(); });
                if (!running) return;
                packet = std::move(packets.front());
                packets.pop_front();
                pendingBytes -= packet.size();
            }
            if (!sendAll(packet.data(), packet.size())) {
                fail("连接已断开，请重新连接");
                return;
            }
        }
    }
    void readLoop() {
        uint8_t command[6];
        size_t offset = 0;
        while (running) {
            ssize_t count = recv(socket.load(), command + offset, sizeof(command) - offset, 0);
            if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (count <= 0) { if (running) fail("连接已断开，请重新连接"); return; }
            offset += static_cast<size_t>(count);
            if (offset != sizeof(command)) continue;
            offset = 0;
            uint32_t serial;
            memcpy(&serial, command + 2, 4);
            serial = ntohl(serial);
            if (command[0] != 0xa1 || command[1] > 1 || serial == 0) {
                fail("声音控制错误，请重新连接"); return;
            }
            std::lock_guard<std::mutex> lock(mutex);
            audioSerial = serial;
            audioOnMac = command[1] == 1;
            lastAudioCommand = std::chrono::steady_clock::now();
        }
    }
    bool audioLeaseLive() const {
        return running && captureStarted && audioSerial != 0 &&
            std::chrono::steady_clock::now() - lastAudioCommand < std::chrono::milliseconds(6000);
    }
    void stop(bool user = true) {
        running = false;
        captureStarted = false;
        int fd = socket.load();
        if (fd >= 0) shutdown(fd, SHUT_RDWR);
        wake.notify_all();
        if (capture) {
            OH_AVScreenCapture_StopScreenCapture(capture);
            OH_AVScreenCapture_Release(capture);
            capture = nullptr;
        }
        if (encoder) {
            OH_VideoEncoder_Stop(encoder);
            OH_VideoEncoder_Destroy(encoder);
            encoder = nullptr;
        }
        if (surface) { OH_NativeWindow_DestroyNativeWindow(surface); surface = nullptr; }
        if (writer.joinable()) writer.join();
        if (reader.joinable()) reader.join();
        fd = socket.exchange(-1);
        if (fd >= 0) close(fd);
        std::lock_guard<std::mutex> lock(mutex);
        packets.clear();
        pendingBytes = 0;
        audioSerial = 0;
        audioOnMac = false;
        if (user) message = "已停止";
    }
    void check(int code, const char *operation) {
        if (code != 0) throw std::runtime_error(std::string(operation) + "失败（" + std::to_string(code) + "）");
    }
    void start(const std::string &host, const std::string &code, int width, int height, int port) {
        std::lock_guard<std::mutex> lock(lifecycle);
        stop(false);
        try {
            state("正在连接 Mac");
            addrinfo hints{};
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV;
            addrinfo *resolved = nullptr;
            if (getaddrinfo(host.c_str(), std::to_string(port).c_str(), &hints, &resolved) != 0)
                throw std::runtime_error("Mac 地址无效，请重新搜索或输入 IP 地址");
            std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> address(resolved, freeaddrinfo);
            if (code.size() != 6 || code.find_first_not_of("0123456789") != std::string::npos)
                throw std::runtime_error("请输入六位连接码");
            int fd = ::socket(address->ai_family, SOCK_STREAM | SOCK_CLOEXEC, 0);
            if (fd < 0) throw std::runtime_error("无法创建网络连接");
            socket = fd;
            fcntl(fd, F_SETFL, O_NONBLOCK);
            if (connect(fd, address->ai_addr, address->ai_addrlen) < 0 && errno != EINPROGRESS)
                throw std::runtime_error("无法连接 Mac，请检查地址和局域网");
            pollfd waiter{fd, POLLOUT, 0};
            if (poll(&waiter, 1, 4000) <= 0) throw std::runtime_error("连接 Mac 超时");
            int error = 0; socklen_t errorSize = sizeof(error);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorSize) || error)
                throw std::runtime_error("Mac 未开启接收，请先打开鸿蒙投屏");
            fcntl(fd, F_SETFL, 0);
            timeval timeout{3, 0};
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            std::string hello = "HCAST02 " + code;
            if (!sendAll(reinterpret_cast<const uint8_t *>(hello.data()), hello.size()))
                throw std::runtime_error("发送连接码失败");
            uint8_t accepted = 0;
            if (recv(fd, &accepted, 1, MSG_WAITALL) != 1 || accepted != 1)
                throw std::runtime_error("请将 Mac 接收端更新到 0.4.0，并重新连接");
            encoder = OH_VideoEncoder_CreateByMime("video/avc");
            if (!encoder) throw std::runtime_error("设备无法创建 H.264 编码器");
            OH_AVCodecCallback callbacks{};
            callbacks.onError = [](OH_AVCodec *, int32_t code, void *data) {
                static_cast<Sender *>(data)->fail("视频编码错误 " + std::to_string(code));
            };
            callbacks.onStreamChanged = [](OH_AVCodec *, OH_AVFormat *, void *) {};
            callbacks.onNeedInputBuffer = [](OH_AVCodec *, uint32_t, OH_AVBuffer *, void *) {};
            callbacks.onNewOutputBuffer = [](OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *data) {
                OH_AVCodecBufferAttr attr{};
                if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0) {
                    auto address = OH_AVBuffer_GetAddr(buffer);
                    if (address) static_cast<Sender *>(data)->enqueue(1, address + attr.offset, attr.size);
                }
                OH_VideoEncoder_FreeOutputBuffer(codec, index);
            };
            check(OH_VideoEncoder_RegisterCallback(encoder, callbacks, this), "设置编码回调");
            OH_AVFormat *format = OH_AVFormat_Create();
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
            OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, 6000000);
            OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, 30.0);
            OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
            int configured = OH_VideoEncoder_Configure(encoder, format);
            OH_AVFormat_Destroy(format);
            check(configured, "设置编码参数");
            check(OH_VideoEncoder_GetSurface(encoder, &surface), "创建编码表面");
            check(OH_VideoEncoder_Prepare(encoder), "准备编码器");
            capture = OH_AVScreenCapture_Create();
            if (!capture) throw std::runtime_error("无法创建录屏服务");
            check(OH_AVScreenCapture_SetErrorCallback(capture, [](OH_AVScreenCapture *, int32_t code, void *data) {
                static_cast<Sender *>(data)->fail("录屏错误 " + std::to_string(code));
            }, this), "设置录屏回调");
            check(OH_AVScreenCapture_SetStateCallback(capture, [](OH_AVScreenCapture *, OH_AVScreenCaptureStateCode code, void *data) {
                auto self = static_cast<Sender *>(data);
                if (code == OH_SCREEN_CAPTURE_STATE_STARTED) {
                    self->captureStarted = true;
                    self->state("正在投屏到 Mac");
                    const uint8_t capability[] = {1};
                    self->enqueue(3, capability, sizeof(capability));
                }
                else if (code == OH_SCREEN_CAPTURE_STATE_CANCELED || code == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_USER ||
                         code == OH_SCREEN_CAPTURE_STATE_INTERRUPTED_BY_OTHER || code == OH_SCREEN_CAPTURE_STATE_STOPPED_BY_CALL)
                    self->fail("录屏已结束");
            }, this), "设置录屏状态");
            check(OH_AVScreenCapture_SetDataCallback(capture, [](OH_AVScreenCapture *, OH_AVBuffer *buffer,
                OH_AVScreenCaptureBufferType type, int64_t, void *data) {
                if (type != OH_SCREEN_CAPTURE_BUFFERTYPE_AUDIO_INNER) return;
                OH_AVCodecBufferAttr attr{};
                if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0) {
                    auto address = OH_AVBuffer_GetAddr(buffer);
                    if (address) static_cast<Sender *>(data)->enqueue(2, address + attr.offset, attr.size);
                }
            }, this), "设置音频回调");
            OH_AVScreenCaptureConfig config{};
            config.captureMode = OH_CAPTURE_HOME_SCREEN;
            config.dataType = OH_ORIGINAL_STREAM;
            config.videoInfo.videoCapInfo.videoFrameWidth = width;
            config.videoInfo.videoCapInfo.videoFrameHeight = height;
            config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
            config.audioInfo.innerCapInfo = {48000, 2, OH_ALL_PLAYBACK};
            check(OH_AVScreenCapture_Init(capture, config), "初始化录屏");
            OH_AVScreenCapture_SetMicrophoneEnabled(capture, false);
            OH_AVScreenCapture_SetCanvasRotation(capture, true);
            running = true;
            writer = std::thread([this] { writeLoop(); });
            reader = std::thread([this] { readLoop(); });
            check(OH_VideoEncoder_Start(encoder), "启动编码器");
            state("请在系统提示中允许录屏");
            check(OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, surface), "启动录屏");
        } catch (...) { stop(false); throw; }
    }
} sender;

struct StartWork { napi_async_work work; napi_deferred promise; std::string host, code, error; int width, height, port = 47999; };
std::string stringArg(napi_env env, napi_value value) {
    char text[256]; size_t length = 0;
    if (napi_get_value_string_utf8(env, value, text, sizeof(text), &length) != napi_ok) return "";
    return std::string(text, length);
}
napi_value Start(napi_env env, napi_callback_info info) {
    size_t count = 5; napi_value args[5]; napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    if (count < 4) { napi_throw_type_error(env, nullptr, "需要地址、连接码和画面尺寸"); return nullptr; }
    if (sender.starting.exchange(true)) { napi_throw_error(env, nullptr, "连接正在进行中"); return nullptr; }
    auto work = new StartWork{};
    work->host = stringArg(env,args[0]); work->code = stringArg(env,args[1]);
    napi_get_value_int32(env,args[2],&work->width); napi_get_value_int32(env,args[3],&work->height);
    if (count == 5) napi_get_value_int32(env,args[4],&work->port);
    if (work->width < 16 || work->height < 16 || work->width > 1920 || work->height > 1920 || work->port < 1 || work->port > 65535) {
        sender.starting = false; delete work; napi_throw_range_error(env,nullptr,"画面尺寸无效"); return nullptr;
    }
    napi_value promise, name;
    napi_create_promise(env,&work->promise,&promise);
    napi_create_string_utf8(env,"StartCasting",NAPI_AUTO_LENGTH,&name);
    napi_create_async_work(env,nullptr,name,[](napi_env,void *data) {
        auto work=static_cast<StartWork *>(data);
        try { sender.start(work->host,work->code,work->width,work->height,work->port); }
        catch(const std::exception &error) { work->error=error.what(); sender.state(work->error); }
    },[](napi_env env,napi_status,void *data) {
        auto work=static_cast<StartWork *>(data); napi_value result;
        if(work->error.empty()) { napi_get_undefined(env,&result); napi_resolve_deferred(env,work->promise,result); }
        else { napi_value text; napi_create_string_utf8(env,work->error.c_str(),NAPI_AUTO_LENGTH,&text); napi_create_error(env,nullptr,text,&result); napi_reject_deferred(env,work->promise,result); }
        sender.starting=false; napi_delete_async_work(env,work->work); delete work;
    },work,&work->work);
    napi_queue_async_work(env,work->work); return promise;
}
napi_value Stop(napi_env env,napi_callback_info) {
    // start is disabled in ArkUI while connecting, so stop never blocks behind a connect.
    std::lock_guard<std::mutex> lock(sender.lifecycle); sender.stop();
    napi_value value; napi_get_undefined(env,&value); return value;
}
napi_value Status(napi_env env,napi_callback_info) {
    std::lock_guard<std::mutex> lock(sender.mutex); napi_value value;
    napi_create_string_utf8(env,sender.message.c_str(),NAPI_AUTO_LENGTH,&value); return value;
}
napi_value AudioRequest(napi_env env, napi_callback_info) {
    std::lock_guard<std::mutex> lock(sender.mutex);
    napi_value object, serial, enabled, live;
    napi_create_object(env, &object);
    napi_create_uint32(env, sender.audioSerial, &serial);
    napi_get_boolean(env, sender.audioOnMac, &enabled);
    napi_get_boolean(env, sender.audioLeaseLive(), &live);
    napi_set_named_property(env, object, "serial", serial);
    napi_set_named_property(env, object, "enabled", enabled);
    napi_set_named_property(env, object, "live", live);
    return object;
}
napi_value AudioReply(napi_env env, napi_callback_info info) {
    size_t count = 3; napi_value args[3];
    napi_get_cb_info(env, info, &count, args, nullptr, nullptr);
    uint32_t serial = 0; bool enabled = false, success = false;
    if (count != 3 || napi_get_value_uint32(env, args[0], &serial) != napi_ok ||
        napi_get_value_bool(env, args[1], &enabled) != napi_ok ||
        napi_get_value_bool(env, args[2], &success) != napi_ok) {
        napi_throw_type_error(env, nullptr, "无效的声音确认"); return nullptr;
    }
    bool current;
    { std::lock_guard<std::mutex> lock(sender.mutex);
      current = serial == sender.audioSerial && sender.audioLeaseLive(); }
    if (current) {
        uint8_t reply[6]; uint32_t network = htonl(serial);
        memcpy(reply, &network, 4); reply[4] = enabled; reply[5] = success ? 0 : 1;
        sender.enqueue(4, reply, sizeof(reply));
    }
    napi_value value; napi_get_undefined(env, &value); return value;
}
napi_value Init(napi_env env,napi_value exports) {
    napi_add_env_cleanup_hook(env, [](void *) {
        std::lock_guard<std::mutex> lock(sender.lifecycle);
        sender.stop();
    }, nullptr);
    napi_property_descriptor props[]={{"start",nullptr,Start,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"stop",nullptr,Stop,nullptr,nullptr,nullptr,napi_default,nullptr},{"status",nullptr,Status,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"audioRequest",nullptr,AudioRequest,nullptr,nullptr,nullptr,napi_default,nullptr},
        {"audioReply",nullptr,AudioReply,nullptr,nullptr,nullptr,napi_default,nullptr}};
    napi_define_properties(env,exports,5,props); return exports;
}
}
static napi_module module={1,0,nullptr,Init,"cast",nullptr,{0}};
extern "C" __attribute__((constructor)) void RegisterModule() { napi_module_register(&module); }
