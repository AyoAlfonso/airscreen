import Foundation
import AudioToolbox

/// Interleaved 16-bit 48 kHz stereo PCM -> Opus, 20 ms per packet.
///
/// Uses the Apple `aenc/opus` encoder in AudioToolbox, so there is no third
/// party dependency. Raw PCM on the data channel costs 1.536 Mbps; Opus at the
/// default bit rate costs roughly a tenth of that and leaves the headroom for
/// video, which is what the link is actually short of.
///
/// Not thread safe. `encode` is called only from the capture queue.
final class OpusEncoder {
    static let sampleRate = 48_000
    static let channels = 2
    /// 20 ms. The TV's MediaCodec decoder is configured for the same frame size.
    static let framesPerPacket = 960
    static let bytesPerPacket = framesPerPacket * channels * MemoryLayout<Int16>.size

    /// Returned by the input callback when the converter wants more PCM than we
    /// have buffered. Surfacing a distinct status keeps the converter's internal
    /// state intact; returning 0 packets with `noErr` would read as end of
    /// stream and reset the encoder between packets.
    private static let starved: OSStatus = 0x6E6F6474  // 'nodt'

    private var converter: AudioConverterRef?
    /// Linear staging buffer, compacted between packets.
    private let capacityFrames = sampleRate * 2
    private var staging: UnsafeMutablePointer<Int16>
    private var writeCursor = 0   // in frames
    private var readCursor = 0    // in frames
    private var output: UnsafeMutablePointer<UInt8>
    private let outputCapacity = 4_000

    private(set) var droppedFrames = 0

    var framesAvailable: Int { writeCursor - readCursor }

    init?(bitRate: UInt32 = 128_000) {
        staging = UnsafeMutablePointer<Int16>.allocate(capacity: capacityFrames * Self.channels)
        output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputCapacity)

        var source = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.channels * 2),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.channels * 2),
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var created: AudioConverterRef?
        guard AudioConverterNew(&source, &destination, &created) == noErr, let created else {
            staging.deallocate()
            output.deallocate()
            return nil
        }
        converter = created
        var rate = bitRate
        AudioConverterSetProperty(created, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &rate)
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        staging.deallocate()
        output.deallocate()
    }

    /// - Parameter pcm: interleaved little-endian Int16, 48 kHz stereo.
    /// - Returns: zero or more complete Opus packets.
    func encode(pcm: Data) -> [Data] {
        append(pcm)
        var packets: [Data] = []
        while framesAvailable >= Self.framesPerPacket {
            guard let packet = encodeOnePacket() else { break }
            packets.append(packet)
        }
        compact()
        return packets
    }

    private func append(_ pcm: Data) {
        let incomingFrames = pcm.count / (Self.channels * 2)
        guard incomingFrames > 0 else { return }
        if writeCursor + incomingFrames > capacityFrames { compact() }
        if writeCursor + incomingFrames > capacityFrames {
            // Consumer has stalled for over a second. Keep the newest audio.
            droppedFrames += framesAvailable
            readCursor = 0
            writeCursor = 0
        }
        let room = capacityFrames - writeCursor
        let take = min(incomingFrames, room)
        guard take > 0 else { return }
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(staging + writeCursor * Self.channels, base, take * Self.channels * 2)
        }
        writeCursor += take
        if take < incomingFrames { droppedFrames += incomingFrames - take }
    }

    private func compact() {
        guard readCursor > 0 else { return }
        let remaining = framesAvailable
        if remaining > 0 {
            memmove(staging, staging + readCursor * Self.channels, remaining * Self.channels * 2)
        }
        readCursor = 0
        writeCursor = remaining
    }

    private func encodeOnePacket() -> Data? {
        guard let converter else { return nil }
        var packetCount: UInt32 = 1
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(Self.channels),
                mDataByteSize: UInt32(outputCapacity),
                mData: UnsafeMutableRawPointer(output)
            )
        )
        var description = AudioStreamPacketDescription()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioConverterFillComplexBuffer(
            converter, Self.inputProc, context, &packetCount, &bufferList, &description
        )
        guard status == noErr || status == Self.starved, packetCount == 1 else { return nil }
        let size = Int(bufferList.mBuffers.mDataByteSize)
        guard size > 0 else { return nil }
        return Data(bytes: output, count: size)
    }

    private static let inputProc: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, userData in
        guard let userData else {
            ioNumberDataPackets.pointee = 0
            return starved
        }
        let encoder = Unmanaged<OpusEncoder>.fromOpaque(userData).takeUnretainedValue()
        let available = encoder.framesAvailable
        guard available > 0 else {
            ioNumberDataPackets.pointee = 0
            return starved
        }
        let give = min(Int(ioNumberDataPackets.pointee), available)
        ioNumberDataPackets.pointee = UInt32(give)
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers.mNumberChannels = UInt32(channels)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(give * channels * 2)
        ioData.pointee.mBuffers.mData =
            UnsafeMutableRawPointer(encoder.staging + encoder.readCursor * channels)
        encoder.readCursor += give
        return noErr
    }
}
