import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "com.airscreen.capture")
    private var stream: SCStream?
    private var audioCount = 0
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    func start(width: Int = 1920, height: Int = 1080, fps: Int = 60) async throws {
        print("CAPTURE: start")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "AirScreen", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        print("CAPTURE: started audio=\(config.capturesAudio)")
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    private var frameCount = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        if type == .screen {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            frameCount += 1
            if frameCount % 120 == 1 { print("CAPTURE: frame \(frameCount)") }
            onFrame?(pixelBuffer, pts)
        } else if type == .audio {
            if let pcm = AudioPCM.int16Interleaved(from: sampleBuffer) {
                audioCount += 1
                if audioCount % 50 == 1 { print("CAPTURE: audio \(pcm.count) bytes") }
                onAudio?(pcm)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("CAPTURE: stopped \(error)")
        onError?("Screen capture stopped: \(error.localizedDescription)")
    }
}
