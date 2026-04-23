import Testing
@testable import SoundManager

@Suite
@MainActor
struct MixerViewModelTests {
    // MARK: - 初期化

    @Test
    func initialLoad_populatesDevicesAndReadsCurrentVolume() {
        let mock = MockAudioObjectClient()
        let speaker = AudioDevice.makeStub(id: 10, name: "Speaker")
        let headphones = AudioDevice.makeStub(id: 20, name: "Headphones")
        mock.outputDevicesToReturn = [speaker, headphones]
        mock.defaultOutputDeviceToReturn = 10
        mock.volumesByID = [10: 0.5, 20: 0.9]

        let vm = MixerViewModel(client: mock)

        #expect(vm.outputDevices == [speaker, headphones])
        #expect(vm.selectedOutputID == 10)
        #expect(vm.volumeIsReadable)
        #expect(abs(vm.volume - 0.5) < 0.0001)
    }

    @Test
    func initialLoad_doesNotTriggerSetVolumeOrSetDefaultOutput() {
        // refresh() 時に selectedOutputID が didSet を発火しても
        // suppressXxxWrite フラグで client への冗長な書込み呼び出しが走らない
        let mock = MockAudioObjectClient()
        mock.outputDevicesToReturn = [AudioDevice.makeStub(id: 10, name: "A")]
        mock.defaultOutputDeviceToReturn = 10
        mock.volumesByID = [10: 0.5]

        _ = MixerViewModel(client: mock)

        #expect(mock.setVolumeCalls.isEmpty)
        #expect(mock.setDefaultOutputCalls.isEmpty)
    }

    // MARK: - デバイス選択

    @Test
    func selectingDifferentDevice_callsSetDefaultOutputAndReadsNewVolume() {
        let mock = MockAudioObjectClient()
        mock.outputDevicesToReturn = [
            AudioDevice.makeStub(id: 10, name: "A"),
            AudioDevice.makeStub(id: 20, name: "B")
        ]
        mock.defaultOutputDeviceToReturn = 10
        mock.volumesByID = [10: 0.3, 20: 0.7]

        let vm = MixerViewModel(client: mock)

        vm.selectedOutputID = 20

        #expect(mock.setDefaultOutputCalls == [20])
        #expect(vm.selectedOutputID == 20)
        #expect(abs(vm.volume - 0.7) < 0.0001)
    }

    @Test
    func selectingSameDevice_doesNotCallSetDefaultOutput() {
        let mock = MockAudioObjectClient()
        mock.outputDevicesToReturn = [AudioDevice.makeStub(id: 10, name: "A")]
        mock.defaultOutputDeviceToReturn = 10
        mock.volumesByID = [10: 0.3]

        let vm = MixerViewModel(client: mock)
        let baseline = mock.setDefaultOutputCalls.count

        vm.selectedOutputID = 10

        #expect(mock.setDefaultOutputCalls.count == baseline)
    }

    // MARK: - 音量変更

    @Test
    func changingVolume_callsSetOutputVolumeScalarOnSelectedDevice() {
        let mock = MockAudioObjectClient()
        mock.outputDevicesToReturn = [AudioDevice.makeStub(id: 10, name: "A")]
        mock.defaultOutputDeviceToReturn = 10
        mock.volumesByID = [10: 0.3]

        let vm = MixerViewModel(client: mock)
        let baseline = mock.setVolumeCalls.count

        vm.volume = 0.8

        #expect(mock.setVolumeCalls.count == baseline + 1)
        #expect(mock.setVolumeCalls.last?.id == 10)
        let lastVolume = mock.setVolumeCalls.last?.volume ?? 0
        #expect(abs(lastVolume - 0.8) < 0.0001)
    }

    // MARK: - 読み取り不可デバイス

    @Test
    func volumeUnreadable_whenDeviceHasNoVolumeProperty() {
        let mock = MockAudioObjectClient()
        mock.outputDevicesToReturn = [AudioDevice.makeStub(id: 10, name: "Virtual")]
        mock.defaultOutputDeviceToReturn = 10
        // volumesByID に 10 を設定しない → getOutputVolumeScalar が nil

        let vm = MixerViewModel(client: mock)

        #expect(!vm.volumeIsReadable)
        #expect(vm.volume == 0)
    }

    // MARK: - リフレッシュ

    @Test
    func refresh_rereadsDevicesAndKeepsSelectionStable() {
        let mock = MockAudioObjectClient()
        mock.outputDevicesToReturn = [AudioDevice.makeStub(id: 10, name: "A")]
        mock.defaultOutputDeviceToReturn = 10
        mock.volumesByID = [10: 0.5]

        let vm = MixerViewModel(client: mock)
        let enumerateBaseline = mock.enumerateCount
        let setDefaultBaseline = mock.setDefaultOutputCalls.count
        let setVolumeBaseline = mock.setVolumeCalls.count

        mock.outputDevicesToReturn.append(AudioDevice.makeStub(id: 20, name: "B"))
        vm.refresh()

        #expect(mock.enumerateCount == enumerateBaseline + 1)
        #expect(vm.outputDevices.count == 2)
        #expect(vm.selectedOutputID == 10)
        // refresh 中に冗長な client 書込みは走らない
        #expect(mock.setDefaultOutputCalls.count == setDefaultBaseline)
        #expect(mock.setVolumeCalls.count == setVolumeBaseline)
    }

    // MARK: - 値型契約

    @Test
    func audioDevice_isEquatableByValue() {
        let a = AudioDevice.makeStub(id: 10, name: "A")
        let b = AudioDevice.makeStub(id: 10, name: "A")
        let c = AudioDevice.makeStub(id: 20, name: "A")

        #expect(a == b)
        #expect(a != c)
    }
}
