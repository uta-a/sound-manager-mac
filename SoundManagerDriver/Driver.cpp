// SoundManagerDriver - M2: 最小 HAL Plugin (仮想出力デバイス、サイレントハンドラ)
//
// このドライバは libASPL (MIT) 上に構築される。
// 本 M2 段階ではアプリが書込んだオーディオデータを一切加工せず破棄する。
// 仮想デバイスがシステムに現れ、coreaudiod によりロードされ、
// 44.1 / 48 / 96 kHz の複数 sample rate で動作することを検証するのが目的。
//
// M4 で per-client gain 処理とループバック入力ストリームを追加し、
// SoundSource 相当の per-app volume 機能に発展させる。

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <vector>

namespace {

// 対応 sample rate (M2 の fault matrix 要件より)
constexpr Float64 kSupportedSampleRates[] = {44100.0, 48000.0, 96000.0};
constexpr UInt32 kChannelCount = 2;
constexpr Float64 kDefaultSampleRate = 48000.0;

// Float32 interleaved stereo の ASBD を作る
// M4 の per-client gain / ミックスで Float32 が扱いやすいため、M2 から統一する。
AudioStreamBasicDescription MakeFloat32StereoASBD(Float64 sampleRate) {
    AudioStreamBasicDescription desc{};
    desc.mSampleRate = sampleRate;
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

// 何もしない IO ハンドラ。M2 では音声の加工・転送は行わない。
// OnStartIO / OnStopIO のフックを明示しておくことで M4 の拡張位置を示す。
class SilentHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override {
        return kAudioHardwareNoError;
    }

    void OnStopIO() override {
        // M4 でループバックリングバッファの flush 等を入れる想定
    }

    // OnWriteMixedOutput / OnReadMixedInput は意図的に未実装 (no-op)
};

std::shared_ptr<aspl::Driver> CreateSoundManagerDriver() {
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "SoundManager";
    deviceParams.Manufacturer = "SoundManager";
    deviceParams.SampleRate = kDefaultSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    deviceParams.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);
    device->AddStreamWithControlsAsync(aspl::Direction::Output);

    // Device レベル: 対応 sample rate を複数登録
    std::vector<AudioValueRange> sampleRateRanges;
    sampleRateRanges.reserve(std::size(kSupportedSampleRates));
    for (Float64 rate : kSupportedSampleRates) {
        sampleRateRanges.push_back(AudioValueRange{rate, rate});
    }
    device->SetAvailableSampleRatesAsync(sampleRateRanges);

    // Stream レベル: 同じ sample rate リストで Float32 stereo の available formats を登録
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

    auto handler = std::make_shared<SilentHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

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
