// SoundManagerDriver - M2: 最小 HAL Plugin (仮想出力デバイス、サイレントハンドラ)
//
// このドライバは libASPL (MIT) 上に構築される。
// 本 M2 段階ではアプリが書込んだオーディオデータを一切加工せず破棄する。
// 仮想デバイスがシステムに現れ、coreaudiod によりロードされることを検証するのが目的。
//
// M4 で per-client gain 処理とループバック入力ストリームを追加し、
// SoundSource 相当の per-app volume 機能に発展させる。

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

namespace {

constexpr UInt32 kSampleRate = 48000;
constexpr UInt32 kChannelCount = 2;

// 何もしない IO ハンドラ。M2 では音声の加工・転送は行わない。
// aspl::IORequestHandler のデフォルト動作 (どのコールバックも実装しない) でも
// 同等だが、OnStartIO / OnStopIO のフックを明示しておくことで今後の拡張位置を示す。
class SilentHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler {
public:
    OSStatus OnStartIO() override {
        return kAudioHardwareNoError;
    }

    void OnStopIO() override {
        // 後の M4 でループバックリングバッファの flush 等を入れる想定
    }

    // OnWriteMixedOutput / OnReadMixedInput は意図的に未実装 (no-op)
};

std::shared_ptr<aspl::Driver> CreateSoundManagerDriver() {
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "SoundManager";
    deviceParams.Manufacturer = "SoundManager";
    deviceParams.SampleRate = kSampleRate;
    deviceParams.ChannelCount = kChannelCount;
    deviceParams.EnableMixing = true;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);
    device->AddStreamWithControlsAsync(aspl::Direction::Output);

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
    // HAL がこの plugin をアンロードするまで alive に保つために static で保持する。
    static std::shared_ptr<aspl::Driver> driver = CreateSoundManagerDriver();
    return driver->GetReference();
}
