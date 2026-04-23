import AudioToolbox
import CoreAudio
import Foundation

/// SoundManager 仮想デバイスの Input ストリームから取ったオーディオを
/// ユーザーが選んだ実出力デバイスに流す。
/// 内部で 2 本の `AudioDeviceIOProcID` を立て、中間を lock-guarded ring buffer で繋ぐ。
///
/// M4b 最小実装のため、SR は一致している前提 (driver 側で 44.1/48/96kHz 登録済み、
/// 通常はシステムが 48kHz を選ぶ)。SR が異なる場合のリサンプリングは M4e で追加。
///
/// Non-MainActor だが、呼び出し側 (MixerViewModel) が MainActor context から
/// 単一スレッドで操作する前提なので internal state は追加 lock を取らない。
final class LoopbackEngine: @unchecked Sendable {
    private let ringBuffer: LoopbackRingBuffer

    private var inputDeviceID: AudioDeviceID = 0
    private var outputDeviceID: AudioDeviceID = 0
    private var inputProcID: AudioDeviceIOProcID?
    private var outputProcID: AudioDeviceIOProcID?
    private(set) var isRunning: Bool = false

    init(capacitySamples: Int = 96000 * 2 * 2) {
        self.ringBuffer = LoopbackRingBuffer(capacity: capacitySamples)
    }

    deinit {
        teardown()
    }

    func start(input: AudioDeviceID, output: AudioDeviceID) {
        guard input != 0, output != 0, input != output else {
            stop()
            return
        }
        if isRunning, input == inputDeviceID, output == outputDeviceID {
            return
        }
        stop()

        inputDeviceID = input
        outputDeviceID = output
        ringBuffer.reset()

        let buffer = ringBuffer

        var inID: AudioDeviceIOProcID?
        let inStatus = AudioDeviceCreateIOProcIDWithBlock(&inID, input, nil) {
            _, inputData, _, _, _ in
            Self.writeInput(buffer: buffer, inData: inputData)
        }
        guard inStatus == noErr, let inID = inID else { return }

        var outID: AudioDeviceIOProcID?
        let outStatus = AudioDeviceCreateIOProcIDWithBlock(&outID, output, nil) {
            _, _, _, outputData, _ in
            Self.readOutput(buffer: buffer, outData: outputData)
        }
        guard outStatus == noErr, let outID = outID else {
            AudioDeviceDestroyIOProcID(input, inID)
            return
        }

        inputProcID = inID
        outputProcID = outID

        if AudioDeviceStart(input, inID) != noErr || AudioDeviceStart(output, outID) != noErr {
            teardown()
            return
        }
        isRunning = true
    }

    func stop() {
        teardown()
        isRunning = false
    }

    private func teardown() {
        if let id = inputProcID {
            AudioDeviceStop(inputDeviceID, id)
            AudioDeviceDestroyIOProcID(inputDeviceID, id)
            inputProcID = nil
        }
        if let id = outputProcID {
            AudioDeviceStop(outputDeviceID, id)
            AudioDeviceDestroyIOProcID(outputDeviceID, id)
            outputProcID = nil
        }
    }

    // MARK: - Realtime callbacks

    private nonisolated static func writeInput(
        buffer: LoopbackRingBuffer,
        inData: UnsafePointer<AudioBufferList>
    ) {
        let list = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inData)
        )
        for buf in list {
            guard let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            buffer.write(ptr, count: count)
        }
    }

    private nonisolated static func readOutput(
        buffer: LoopbackRingBuffer,
        outData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let list = UnsafeMutableAudioBufferListPointer(outData)
        for buf in list {
            guard let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            buffer.read(into: ptr, count: count)
        }
    }
}

/// Lock-guarded FIFO リングバッファ。realtime thread から push/pop される前提。
/// NSLock は本来は避けたいが M4b の最小実装として許容 (M4e で lockfree 化予定)。
final class LoopbackRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        readIndex = 0
        count = 0
    }

    func write(_ src: UnsafePointer<Float>, count n: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<n {
            storage[writeIndex] = src[i]
            writeIndex = (writeIndex + 1) % capacity
            if count < capacity {
                count += 1
            } else {
                // overflow: 古いサンプルを捨てて最新を残す
                readIndex = (readIndex + 1) % capacity
            }
        }
    }

    func read(into dst: UnsafeMutablePointer<Float>, count n: Int) {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<n {
            if count > 0 {
                dst[i] = storage[readIndex]
                readIndex = (readIndex + 1) % capacity
                count -= 1
            } else {
                dst[i] = 0  // underflow → 無音
            }
        }
    }
}
