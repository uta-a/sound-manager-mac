// SoundManagerDriver - M4a/M4b: 仮想デバイス + per-app gain + ループバック入力
//
// libASPL を利用し、以下を提供する:
//   1. SoundManager 仮想デバイス (Float32 stereo, 44.1/48/96 kHz)
//      Output stream (アプリからの書込み) と Input stream (ループバック読取) の
//      両方向を持つ。同一 Device 上の両端点なので SampleRate / ChannelCount が一致する。
//   2. クライアント (PID, bundleID) 追跡と kSMCustomPropertyActiveClients (read-only)
//   3. kSMCustomPropertyAppVolumes (read/write)
//      OnProcessClientOutput で per-client の gain をバッファに乗算する。
//   4. OnWriteMixedOutput で mixed 後の bytes を内部リングバッファに push、
//      OnReadClientInput で pop して Input stream の client に渡す。
//      これにより SoundManager.app の LoopbackEngine が選択した実出力デバイスへ
//      音を流せるようになる。
//
// ロックは std::mutex で単純化している (M4e で DoubleBuffer / atomic 化予定)。

#include "../Shared/SMTypes.h"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cstddef>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr Float64 kSupportedSampleRates[] = {44100.0, 48000.0, 96000.0};
constexpr UInt32 kChannelCount = 2;
constexpr Float64 kDefaultSampleRate = 48000.0;

// ループバックバッファの最大サンプル数 (Float32 interleaved stereo)。
// 96kHz × 2ch × 1 秒分のゆとり。overflow 時は古いサンプルを捨てる (最新優先)。
constexpr std::size_t kLoopbackBufferSamples =
    static_cast<std::size_t>(96000 * 2 * 1);

AudioStreamBasicDescription MakeFloat32StereoASBD(Float64 sample_rate) {
    AudioStreamBasicDescription desc{};
    desc.mSampleRate = sample_rate;
    desc.mFormatID = kAudioFormatLinearPCM;
    desc.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked;
    desc.mBitsPerChannel = 32;
    desc.mChannelsPerFrame = kChannelCount;
    desc.mBytesPerFrame = sizeof(Float32) * kChannelCount;
    desc.mFramesPerPacket = 1;
    desc.mBytesPerPacket = desc.mBytesPerFrame * desc.mFramesPerPacket;
    return desc;
}

struct ClientRecord {
    pid_t pid = 0;
    std::string bundle_id;
    bool io_active = false;
};

// シンプルな FIFO サンプルキュー。realtime スレッドから push/pop される。
// mutex ロックはアンチパターン気味だが M4b の最小実装として許容。M4e で改良。
class LoopbackBuffer {
public:
    void Push(const Float32* data, std::size_t samples) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (std::size_t i = 0; i < samples; ++i) {
            queue_.push_back(data[i]);
        }
        while (queue_.size() > kLoopbackBufferSamples) {
            queue_.pop_front();
        }
    }

    void Pop(Float32* dst, std::size_t samples) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (std::size_t i = 0; i < samples; ++i) {
            if (queue_.empty()) {
                dst[i] = 0.0f;  // underflow → zero fill
            } else {
                dst[i] = queue_.front();
                queue_.pop_front();
            }
        }
    }

    void Reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        queue_.clear();
    }

private:
    std::deque<Float32> queue_;
    std::mutex mutex_;
};

class Handler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override { return kAudioHardwareNoError; }
    void OnStopIO() override { loopback_.Reset(); }

    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override {
        auto client = aspl::ControlRequestHandler::OnAddClient(info);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            clients_.insert_or_assign(
                info.ClientID,
                ClientRecord{info.ProcessID, info.BundleID, false});
        }
        NotifyActiveClientsChanged();
        return client;
    }

    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            clients_.erase(client->GetClientID());
        }
        NotifyActiveClientsChanged();
        aspl::ControlRequestHandler::OnRemoveClient(client);
    }

    void MarkClientIOStarted(UInt32 client_id) {
        bool changed = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (auto it = clients_.find(client_id); it != clients_.end()) {
                if (!it->second.io_active) {
                    it->second.io_active = true;
                    changed = true;
                }
            }
        }
        if (changed) NotifyActiveClientsChanged();
    }

    void MarkClientIOStopped(UInt32 client_id) {
        bool changed = false;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (auto it = clients_.find(client_id); it != clients_.end()) {
                if (it->second.io_active) {
                    it->second.io_active = false;
                    changed = true;
                }
            }
        }
        if (changed) NotifyActiveClientsChanged();
    }

    CFPropertyListRef CopyActiveClients() const {
        std::lock_guard<std::mutex> lock(mutex_);

        CFMutableArrayRef array = CFArrayCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

        for (const auto& [client_id, record] : clients_) {
            if (!record.io_active) continue;

            CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 2,
                &kCFCopyStringDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);

            int32_t pid = static_cast<int32_t>(record.pid);
            CFNumberRef pid_number = CFNumberCreate(
                kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
            CFDictionarySetValue(dict, CFSTR(kSMClientInfoKey_PID), pid_number);
            CFRelease(pid_number);

            CFStringRef bundle_id_ref = CFStringCreateWithCString(
                kCFAllocatorDefault,
                record.bundle_id.c_str(),
                kCFStringEncodingUTF8);
            CFDictionarySetValue(dict, CFSTR(kSMClientInfoKey_BundleID), bundle_id_ref);
            CFRelease(bundle_id_ref);

            CFArrayAppendValue(array, dict);
            CFRelease(dict);
        }
        return array;
    }

    CFPropertyListRef CopyAppVolumes() const {
        std::lock_guard<std::mutex> lock(mutex_);
        CFMutableArrayRef array = CFArrayCreateMutable(
            kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);

        for (const auto& [bundle_id, gain] : bundle_gains_) {
            CFMutableDictionaryRef dict = CFDictionaryCreateMutable(
                kCFAllocatorDefault, 2,
                &kCFCopyStringDictionaryKeyCallBacks,
                &kCFTypeDictionaryValueCallBacks);

            CFStringRef bundle_ref = CFStringCreateWithCString(
                kCFAllocatorDefault, bundle_id.c_str(), kCFStringEncodingUTF8);
            CFDictionarySetValue(dict, CFSTR(kSMAppVolumeKey_BundleID), bundle_ref);
            CFRelease(bundle_ref);

            Float32 gain_value = gain;
            CFNumberRef gain_ref = CFNumberCreate(
                kCFAllocatorDefault, kCFNumberFloat32Type, &gain_value);
            CFDictionarySetValue(dict, CFSTR(kSMAppVolumeKey_Gain), gain_ref);
            CFRelease(gain_ref);

            CFArrayAppendValue(array, dict);
            CFRelease(dict);
        }
        return array;
    }

    void SetAppVolumes(CFPropertyListRef value) {
        if (value == nullptr) return;
        if (CFGetTypeID(value) != CFArrayGetTypeID()) return;

        CFArrayRef array = static_cast<CFArrayRef>(value);
        CFIndex count = CFArrayGetCount(array);

        std::map<std::string, Float32> new_map;
        for (CFIndex i = 0; i < count; ++i) {
            CFTypeRef raw = CFArrayGetValueAtIndex(array, i);
            if (!raw || CFGetTypeID(raw) != CFDictionaryGetTypeID()) continue;
            CFDictionaryRef dict = static_cast<CFDictionaryRef>(raw);

            CFStringRef bundle_ref = static_cast<CFStringRef>(
                CFDictionaryGetValue(dict, CFSTR(kSMAppVolumeKey_BundleID)));
            CFNumberRef gain_ref = static_cast<CFNumberRef>(
                CFDictionaryGetValue(dict, CFSTR(kSMAppVolumeKey_Gain)));
            if (!bundle_ref || !gain_ref) continue;

            char buf[256] = {0};
            if (!CFStringGetCString(bundle_ref, buf, sizeof(buf), kCFStringEncodingUTF8)) {
                continue;
            }
            Float32 gain = 1.0f;
            CFNumberGetValue(gain_ref, kCFNumberFloat32Type, &gain);
            new_map[buf] = std::max(0.0f, std::min(4.0f, gain));
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            bundle_gains_ = std::move(new_map);
        }
        NotifyAppVolumesChanged();
    }

    // Realtime: per-client gain 乗算 (mix 前)
    void OnProcessClientOutput(const std::shared_ptr<aspl::Client>& client,
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override {
        stream->ApplyProcessing(frames, frameCount, channelCount);

        Float32 gain = LookupGainForClient(client->GetClientID());
        if (gain == 1.0f) return;

        const UInt32 total = frameCount * channelCount;
        for (UInt32 i = 0; i < total; ++i) {
            frames[i] *= gain;
        }
    }

    // Realtime: mix 後の Float32 interleaved bytes をループバックバッファに蓄積。
    // bytes は Float32 stereo interleaved であることを期待 (Stream format より保証)。
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        const void* bytes,
        UInt32 bytesCount) override {
        const std::size_t samples = bytesCount / sizeof(Float32);
        loopback_.Push(static_cast<const Float32*>(bytes), samples);
    }

    // Realtime: Input client (LoopbackEngine) にループバックバッファの内容を返す。
    void OnReadClientInput(const std::shared_ptr<aspl::Client>& /*client*/,
        const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 /*timestamp*/,
        void* bytes,
        UInt32 bytesCount) override {
        const std::size_t samples = bytesCount / sizeof(Float32);
        loopback_.Pop(static_cast<Float32*>(bytes), samples);
    }

    void SetDevice(std::weak_ptr<aspl::Device> device) {
        device_ = std::move(device);
    }

private:
    Float32 LookupGainForClient(UInt32 client_id) const {
        std::lock_guard<std::mutex> lock(mutex_);
        auto client_it = clients_.find(client_id);
        if (client_it == clients_.end()) return 1.0f;
        auto gain_it = bundle_gains_.find(client_it->second.bundle_id);
        return gain_it == bundle_gains_.end() ? 1.0f : gain_it->second;
    }

    void NotifyActiveClientsChanged() {
        if (auto device = device_.lock()) {
            device->NotifyPropertyChanged(
                kSMCustomPropertyActiveClients,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain);
        }
    }

    void NotifyAppVolumesChanged() {
        if (auto device = device_.lock()) {
            device->NotifyPropertyChanged(
                kSMCustomPropertyAppVolumes,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain);
        }
    }

    mutable std::mutex mutex_;
    std::map<UInt32, ClientRecord> clients_;
    std::map<std::string, Float32> bundle_gains_;
    std::weak_ptr<aspl::Device> device_;
    LoopbackBuffer loopback_;
};

class TrackingDevice : public aspl::Device {
public:
    using aspl::Device::Device;

    void SetHandler(std::weak_ptr<Handler> handler) {
        handler_ = std::move(handler);
    }

protected:
    OSStatus StartIOImpl(UInt32 client_id, UInt32 start_count) override {
        auto status = aspl::Device::StartIOImpl(client_id, start_count);
        if (status == kAudioHardwareNoError) {
            if (auto h = handler_.lock()) h->MarkClientIOStarted(client_id);
        }
        return status;
    }

    OSStatus StopIOImpl(UInt32 client_id, UInt32 start_count) override {
        if (auto h = handler_.lock()) h->MarkClientIOStopped(client_id);
        return aspl::Device::StopIOImpl(client_id, start_count);
    }

private:
    std::weak_ptr<Handler> handler_;
};

std::shared_ptr<aspl::Driver> CreateSoundManagerDriver() {
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters device_params;
    device_params.Name = "SoundManager";
    device_params.Manufacturer = "SoundManager";
    device_params.SampleRate = kDefaultSampleRate;
    device_params.ChannelCount = kChannelCount;
    device_params.EnableMixing = true;

    auto device = std::make_shared<TrackingDevice>(context, device_params);

    // Output (アプリからの書込み) と Input (LoopbackEngine からの読取) の両方を追加
    device->AddStreamWithControlsAsync(aspl::Direction::Output);
    device->AddStreamWithControlsAsync(aspl::Direction::Input);

    std::vector<AudioValueRange> sample_rate_ranges;
    sample_rate_ranges.reserve(std::size(kSupportedSampleRates));
    for (Float64 rate : kSupportedSampleRates) {
        sample_rate_ranges.push_back(AudioValueRange{rate, rate});
    }
    device->SetAvailableSampleRatesAsync(sample_rate_ranges);

    // 両方向の stream に同じ available formats を適用
    std::vector<AudioStreamRangedDescription> formats;
    formats.reserve(std::size(kSupportedSampleRates));
    for (Float64 rate : kSupportedSampleRates) {
        AudioStreamRangedDescription desc{};
        desc.mFormat = MakeFloat32StereoASBD(rate);
        desc.mSampleRateRange.mMinimum = rate;
        desc.mSampleRateRange.mMaximum = rate;
        formats.push_back(desc);
    }
    if (auto s = device->GetStreamByIndex(aspl::Direction::Output, 0)) {
        s->SetAvailablePhysicalFormatsAsync(formats);
        s->SetAvailableVirtualFormatsAsync(formats);
    }
    if (auto s = device->GetStreamByIndex(aspl::Direction::Input, 0)) {
        s->SetAvailablePhysicalFormatsAsync(formats);
        s->SetAvailableVirtualFormatsAsync(formats);
    }

    auto handler = std::make_shared<Handler>();
    handler->SetDevice(device);
    device->SetHandler(handler);
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    device->RegisterCustomProperty(
        kSMCustomPropertyActiveClients,
        *handler,
        &Handler::CopyActiveClients);

    device->RegisterCustomProperty(
        kSMCustomPropertyAppVolumes,
        *handler,
        &Handler::CopyAppVolumes,
        &Handler::SetAppVolumes);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

}  // namespace

extern "C" void* SoundManagerDriverEntryPoint(CFAllocatorRef /*allocator*/,
                                              CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CreateSoundManagerDriver();
    return driver->GetReference();
}
