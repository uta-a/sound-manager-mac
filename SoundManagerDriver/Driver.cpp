// SoundManagerDriver - M3a+M3b ext: 仮想デバイス + 再生中クライアント検出
//
// libASPL を利用し、以下を提供する:
//   1. SoundManager 仮想出力デバイス (Float32 stereo, 44.1/48/96 kHz)
//   2. クライアント (PID, bundleID) の接続・再生状態の追跡
//   3. カスタムプロパティ kSMCustomPropertyActiveClients を通じて
//      「現在 I/O 中 (実際に音を書込中) の client」のみを UI に公開
//
// 単に Audio Device を列挙・購読しているだけのシステムサービス (coreaudiod 等) は
// I/O を開始しないため、UI には出ない。I/O 状態の追跡は Device::StartIOImpl /
// StopIOImpl を override することで行う (これらは clientID 付きで呼ばれる)。
//
// 音声データ自体は依然として破棄される (SilentHandler 挙動)。M4 で per-client gain
// 処理とループバック入力ストリームを追加予定。

#include "../Shared/SMTypes.h"

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

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

// クライアント情報 + 現時点で I/O 中かどうか
struct ClientRecord {
    pid_t pid = 0;
    std::string bundle_id;
    bool io_active = false;
};

// ControlRequestHandler + IORequestHandler を兼ねるハンドラ。
// クライアント管理と (Device 側からの) I/O 状態通知の受け皿を提供する。
class Handler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override {
        return kAudioHardwareNoError;
    }

    void OnStopIO() override {}

    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override {
        auto client = aspl::ControlRequestHandler::OnAddClient(info);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            clients_.insert_or_assign(
                info.ClientID,
                ClientRecord{info.ProcessID, info.BundleID, false});
        }
        NotifyClientsChanged();
        return client;
    }

    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            clients_.erase(client->GetClientID());
        }
        NotifyClientsChanged();
        aspl::ControlRequestHandler::OnRemoveClient(client);
    }

    // Device の StartIOImpl / StopIOImpl から呼ばれる。clientID ごとに I/O 状態を記録する。
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
        if (changed) NotifyClientsChanged();
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
        if (changed) NotifyClientsChanged();
    }

    // kSMCustomPropertyActiveClients の getter。
    // I/O 中 (io_active == true) の client だけを返す。
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

            CFStringRef bundle_id = CFStringCreateWithCString(
                kCFAllocatorDefault,
                record.bundle_id.c_str(),
                kCFStringEncodingUTF8);
            CFDictionarySetValue(dict, CFSTR(kSMClientInfoKey_BundleID), bundle_id);
            CFRelease(bundle_id);

            CFArrayAppendValue(array, dict);
            CFRelease(dict);
        }
        return array;
    }

    void SetDevice(std::weak_ptr<aspl::Device> device) {
        device_ = std::move(device);
    }

private:
    void NotifyClientsChanged() {
        if (auto device = device_.lock()) {
            device->NotifyPropertyChanged(
                kSMCustomPropertyActiveClients,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain);
        }
    }

    mutable std::mutex mutex_;
    std::map<UInt32, ClientRecord> clients_;
    std::weak_ptr<aspl::Device> device_;
};

// aspl::Device を継承して StartIOImpl / StopIOImpl をオーバーライドする。
// これにより、client 単位の I/O 開始/終了を Handler に伝える。
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

    // Device レベル: 対応 sample rate を複数登録
    std::vector<AudioValueRange> sample_rate_ranges;
    sample_rate_ranges.reserve(std::size(kSupportedSampleRates));
    for (Float64 rate : kSupportedSampleRates) {
        sample_rate_ranges.push_back(AudioValueRange{rate, rate});
    }
    device->SetAvailableSampleRatesAsync(sample_rate_ranges);

    // Stream レベル: Float32 stereo の available formats を複数登録
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
