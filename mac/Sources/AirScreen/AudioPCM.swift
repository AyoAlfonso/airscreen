import Foundation
import CoreMedia
import AudioToolbox

enum AudioPCM {
    /// ScreenCaptureKit system audio -> interleaved 16-bit PCM, 48 kHz stereo.
    static func int16Interleaved(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else { return nil }

        let listSize = AudioBufferList.sizeInBytes(maximumBuffers: channels)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard !buffers.isEmpty else { return nil }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let frames = Int(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }

        var out = Data(capacity: frames * channels * 2)
        func appendSample(_ value: Float) {
            let clamped = max(-1.0, min(1.0, value))
            var sample = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &sample) { out.append(contentsOf: $0) }
        }

        if isNonInterleaved {
            // One buffer per channel.
            for frame in 0..<frames {
                for ch in 0..<channels {
                    guard ch < buffers.count, let mData = buffers[ch].mData else { continue }
                    if isFloat {
                        let p = mData.assumingMemoryBound(to: Float.self)
                        appendSample(p[frame])
                    } else {
                        let p = mData.assumingMemoryBound(to: Int16.self)
                        var sample = p[frame].littleEndian
                        withUnsafeBytes(of: &sample) { out.append(contentsOf: $0) }
                    }
                }
            }
        } else {
            guard let mData = buffers[0].mData else { return nil }
            for frame in 0..<frames {
                for ch in 0..<channels {
                    let index = frame * channels + ch
                    if isFloat {
                        let p = mData.assumingMemoryBound(to: Float.self)
                        appendSample(p[index])
                    } else {
                        let p = mData.assumingMemoryBound(to: Int16.self)
                        var sample = p[index].littleEndian
                        withUnsafeBytes(of: &sample) { out.append(contentsOf: $0) }
                    }
                }
            }
        }
        return out
    }
}
