// SoundManagerDriver - M3 + M4a: 仮想デバイス + 再生中 client 検出 + per-app gain
//
// libASPL を利用し、以下を提供する:
//   1. SoundManager 仮想出力デバイス (Float32 stereo, 44.1/48/96 kHz)
//   2. クライアント (PID, bundleID) の接続・I/O 状態の追跡
//      (Device::StartIOImpl / StopIOImpl を override し client-specific に管理)
//   3. カスタムプロパティ kSMCustomPropertyActiveClients (read-only)
//      I/O 中の client のみ { pid, bundleID } で公開
//   4. カスタムプロパティ kSMCustomPropertyAppVolumes (read/write)
//      UI から bundleID 単位で gain を設定する。Driver は
//      IORequestHandler::OnProcessClientOutput でバッファに gain を乗算する。
//
// M4 で次にやること: ループバック入力ストリームを追加し mixer として完成させる。

#include "../Shared/SMTypes.h"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

constexpr Float64 kSupportedSampleRates[] = {44100.0, 48000.0, 96000.0};
constexpr UInt32 kChannelCount = 2;
constexpr Float64 kDefaultSampleRate = 48000.0;

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

// ControlRequestHandler + IORequestHandler を兼ねるハンドラ。
// クライアント管理、I/O 状態追跡、per-client gain の適用を担う。
class Handler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override { return kAudioHardwareNoError; }
    void OnStopIO() override {}

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

    // I/O 中 (io_active) の client のみ返す。
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

    // kSMCustomPropertyAppVolumes getter.
    // 現在保持している { bundleID: gain } マップを CFArray<CFDictionary> で返す。
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

    // kSMCustomPropertyAppVolumes setter.
    // 受け取った CFArray<CFDict> で bundle_gains_ 全体を置き換える。
    // value の所有権は caller 側なので CFRetain は不要。
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

    // Realtime thread から呼ばれる。ここで per-client gain を適用する。
    // libASPL のデフォルト実装は stream->ApplyProcessing(...) を呼ぶので、
    // その動作を残したうえで gain 乗算を追加する。
    //
    // mutex はリアルタイム的にはアンチパターンだが、M4a の最小実装では妥協する。
    // M4e で DoubleBuffer or atomic スナップショットに最適化する予定。
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
};

// Device::StartIOImpl / StopIOImpl を override して client-specific な I/O 追跡を行う。
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
    device->AddStreamWithControlsAsync(aspl::Direction::Output);

    std::vector<AudioValueRange> sample_rate_ranges;
    sample_rate_ranges.reserve(std::size(kSupportedSampleRates));
    for (Float64 rate : kSupportedSampleRates) {
        sample_rate_ranges.push_back(AudioValueRange{rate, rate});
    }
    device->SetAvailableSampleRatesAsync(sample_rate_ranges);

    if (auto stream = device->GetStreamByIndex(aspl::Direction::Output, 0)) {
        std::vector<AudioStreamRangedDescription> formats;
        formats.reserve(std::size(kSupportedSampleRates));
        for (Float64 rate : kSupportedSampleRates) {
            AudioStreamRangedDescription desc{};
            desc.mFormat = MakeFloat32StereoASBD(rate);
            desc.mSampleRateRange.mMinimum = rate;
            desc.mSampleRateRange.mMaximum = rate;
            formats.push_back(desc);
        }
        stream->SetAvailablePhysicalFormatsAsync(formats);
        stream->SetAvailableVirtualFormatsAsync(formats);
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
