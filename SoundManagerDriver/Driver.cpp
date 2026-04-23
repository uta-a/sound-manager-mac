// SoundManagerDriver - M3a: 仮想デバイス + クライアント検出
//
// M2 で構築した仮想出力デバイスに、接続 client (PID / bundleID) の追跡と
// カスタムプロパティ kSMCustomPropertyActiveClients を追加する。
// UI 側は AudioObjectAddPropertyListenerBlock でこのプロパティを購読することで、
// 現在 SoundManager に音を書き込んでいるアプリ一覧をリアルタイムに取得できる。
//
// 音声データ自体は依然として破棄される (SilentHandler 挙動)。
// M4 で per-client gain 処理とループバック入力ストリームを追加予定。

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

// Float32 interleaved stereo の ASBD (M4 の per-client gain で扱いやすい format)
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

// ControlRequestHandler (クライアント管理) と IORequestHandler (I/O) を兼ねる。
// M3a では音声は破棄し、client list のみ追跡する。
class Handler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    // ---- IO (M3a では no-op) ----

    OSStatus OnStartIO() override {
        return kAudioHardwareNoError;
    }

    void OnStopIO() override {}

    // ---- クライアント追跡 ----

    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override {
        auto client = aspl::ControlRequestHandler::OnAddClient(info);
        {
            std::lock_guard<std::mutex> lock(mutex_);
            clients_.insert_or_assign(
                info.ClientID,
                ClientRecord{info.ProcessID, info.BundleID});
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

    // ---- カスタムプロパティ getter ----

    // kSMCustomPropertyActiveClients の値を返す。
    // 戻り値の所有権は caller に渡る (libASPL が CFRelease する)。
    CFPropertyListRef CopyActiveClients() const {
        std::lock_guard<std::mutex> lock(mutex_);

        CFMutableArrayRef array = CFArrayCreateMutable(
            kCFAllocatorDefault,
            static_cast<CFIndex>(clients_.size()),
            &kCFTypeArrayCallBacks);

        for (const auto& [client_id, record] : clients_) {
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

    // ---- 設定 ----

    // Notify 先の Device を設定する。shared_ptr の循環を避けるため weak で持つ。
    void SetDevice(std::weak_ptr<aspl::Device> device) {
        device_ = std::move(device);
    }

private:
    struct ClientRecord {
        pid_t pid;
        std::string bundle_id;
    };

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

std::shared_ptr<aspl::Driver> CreateSoundManagerDriver() {
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters device_params;
    device_params.Name = "SoundManager";
    device_params.Manufacturer = "SoundManager";
    device_params.SampleRate = kDefaultSampleRate;
    device_params.ChannelCount = kChannelCount;
    device_params.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, device_params);
    device->AddStreamWithControlsAsync(aspl::Direction::Output);

    // Device レベル: 対応 sample rate を複数登録
    std::vector<AudioValueRange> sample_rate_ranges;
    sample_rate_ranges.reserve(std::size(kSupportedSampleRates));
    for (Float64 rate : kSupportedSampleRates) {
        sample_rate_ranges.push_back(AudioValueRange{rate, rate});
    }
    device->SetAvailableSampleRatesAsync(sample_rate_ranges);

    // Stream レベル: 同じ sample rate で Float32 stereo の available formats を登録
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
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    // カスタムプロパティ kSMCustomPropertyActiveClients を Device に登録。
    // 値は Handler::CopyActiveClients() が生成する CFArray<CFDictionary>。
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
    // HAL がアンロードするまで driver を生かすために static で保持。
    static std::shared_ptr<aspl::Driver> driver = CreateSoundManagerDriver();
    return driver->GetReference();
}
