#import "H264VideoEncoderFactory.h"
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

static NSString *const kProfileLevelId = @"42e01f";

@interface VTEncoder : NSObject <RTCVideoEncoder>
@property(nonatomic, copy, nullable) RTCVideoEncoderCallback callback;
@property(nonatomic, assign) VTCompressionSessionRef session;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, assign) uint32_t fps;
@property(nonatomic, assign) uint32_t bitrateKbps;
@property(nonatomic, assign) uint64_t encodeCount;
@property(nonatomic, assign) uint64_t outputCount;
@end

@interface VTEncoder ()
- (void)handleSampleBuffer:(CMSampleBufferRef)sampleBuffer source:(void *)source;
@end

static void VTEncoderOutputCallback(void *refCon, void *sourceFrameRefCon,
                                    OSStatus status, VTEncodeInfoFlags infoFlags,
                                    CMSampleBufferRef sampleBuffer) {
    if (status != noErr || sampleBuffer == NULL) return;
    VTEncoder *encoder = (__bridge VTEncoder *)refCon;
    [encoder handleSampleBuffer:sampleBuffer source:sourceFrameRefCon];
}

@implementation VTEncoder

- (void)setCallback:(RTCVideoEncoderCallback)callback {
    _callback = [callback copy];
}

- (NSInteger)startEncodeWithSettings:(RTCVideoEncoderSettings *)settings
                       numberOfCores:(int)numberOfCores {
    if (getenv("AIRSCREEN_BREAK_H264") != NULL) {
        NSLog(@"VT: AIRSCREEN_BREAK_H264 — simulating no H.264 frames");
        return -1;
    }
    [self releaseEncoder];
    _width = settings.width;
    _height = settings.height;
    _fps = settings.maxFramerate > 0 ? settings.maxFramerate : 30;
    _bitrateKbps = settings.maxBitrate > 0 ? settings.maxBitrate : 8000;

    NSDictionary *spec = @{
        (__bridge NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES
    };
    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault, _width, _height, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)spec, NULL, NULL,
        VTEncoderOutputCallback, (__bridge void *)self, &_session);
    if (status != noErr || _session == NULL) {
        NSLog(@"VT: VTCompressionSessionCreate failed: %d", (int)status);
        return -1;
    }

    VTSessionSetProperty(_session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxFrameDelayCount,
                         (__bridge CFNumberRef)@1);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                         kCFBooleanTrue);
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFNumberRef)@(_fps));
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFNumberRef)@(_fps));
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)@(_bitrateKbps * 1000));
    VTCompressionSessionPrepareToEncodeFrames(_session);

    CFTypeRef usingHW = NULL;
    OSStatus hwStatus = VTSessionCopyProperty(
        _session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        kCFAllocatorDefault, &usingHW);
    NSLog(@"VT: hardware encode status=%d value=%@", (int)hwStatus, usingHW);
    if (usingHW) CFRelease(usingHW);
    NSLog(@"VT: started %dx%d @%u fps, %u kbps", _width, _height, _fps, _bitrateKbps);
    return 0;
}

- (NSInteger)encode:(RTCVideoFrame *)frame
    codecSpecificInfo:(id<RTCCodecSpecificInfo>)info
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
    if (_session == NULL) return -1;
    CVPixelBufferRef pixelBuffer = NULL;
    if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        pixelBuffer = ((RTCCVPixelBuffer *)frame.buffer).pixelBuffer;
    }
    if (pixelBuffer == NULL) return -1;

    CMTime pts = CMTimeMake(frame.timeStampNs, 1000000000);
    VTEncodeInfoFlags flags = 0;
    OSStatus status = VTCompressionSessionEncodeFrame(
        _session, pixelBuffer, pts, kCMTimeInvalid, NULL,
        (void *)(uintptr_t)frame.timeStampNs, &flags);
    _encodeCount++;
    if (status != noErr || _encodeCount % 60 == 1) {
        NSLog(@"VT: encode #%llu status=%d flags=%u", _encodeCount, (int)status, (unsigned)flags);
    }
    return status == noErr ? 0 : -1;
}

- (void)handleSampleBuffer:(CMSampleBufferRef)sampleBuffer source:(void *)source {
    @autoreleasepool {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
        BOOL notSync = NO;
        if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
            CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
            notSync = CFDictionaryContainsKey(dict, kCMSampleAttachmentKey_NotSync);
        }
        BOOL keyFrame = !notSync;

        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (block == NULL) return;
        size_t length = 0;
        char *data = NULL;
        if (CMBlockBufferGetDataPointer(block, 0, NULL, &length, &data) != noErr || data == NULL) return;

        NSMutableData *out = [NSMutableData dataWithCapacity:length + 128];
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (keyFrame && fmt != NULL) {
            size_t count = 0;
            const uint8_t *sps = NULL;
            size_t spsLen = 0;
            const uint8_t *pps = NULL;
            size_t ppsLen = 0;
            int nalHeaderLen = 0;
            if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &sps, &spsLen,
                                                                  &count, &nalHeaderLen) == noErr &&
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &pps, &ppsLen,
                                                                  &count, &nalHeaderLen) == noErr) {
                const uint8_t startCode[4] = {0, 0, 0, 1};
                [out appendBytes:startCode length:4];
                [out appendBytes:sps length:spsLen];
                [out appendBytes:startCode length:4];
                [out appendBytes:pps length:ppsLen];
            }
        }

        size_t offset = 0;
        while (offset + 4 <= length) {
            uint32_t nalLen = 0;
            memcpy(&nalLen, data + offset, 4);
            nalLen = ntohl(nalLen);
            offset += 4;
            if (nalLen == 0 || offset + nalLen > length) break;
            const uint8_t startCode[4] = {0, 0, 0, 1};
            [out appendBytes:startCode length:4];
            [out appendBytes:data + offset length:nalLen];
            offset += nalLen;
        }

        RTCEncodedImage *encoded = [[RTCEncodedImage alloc] init];
        encoded.buffer = out;
        encoded.encodedWidth = _width;
        encoded.encodedHeight = _height;
        int64_t tsNs = (int64_t)(uintptr_t)source;
        encoded.timeStamp = (uint32_t)((tsNs * 90LL) / 1000000LL);
        encoded.captureTimeMs = tsNs / 1000000LL;
        encoded.frameType = keyFrame ? RTCFrameTypeVideoFrameKey : RTCFrameTypeVideoFrameDelta;
        encoded.rotation = RTCVideoRotation_0;

        RTCCodecSpecificInfoH264 *h264 = [[RTCCodecSpecificInfoH264 alloc] init];
        h264.packetizationMode = RTCH264PacketizationModeNonInterleaved;
        _outputCount++;
        if (_outputCount % 60 == 1) {
            NSLog(@"VT: output #%llu key=%d bytes=%lu", _outputCount, keyFrame, (unsigned long)out.length);
        }
        if (self.callback) self.callback(encoded, h264);
    }
}

- (NSInteger)releaseEncoder {
    if (_session != NULL) {
        VTCompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    return 0;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
    _bitrateKbps = bitrateKbit;
    if (framerate > 0) _fps = framerate;
    if (_session == NULL) return 0;
    VTSessionSetProperty(_session, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)@(bitrateKbit * 1000));
    return 0;
}

- (NSString *)implementationName { return @"VideoToolbox H264"; }
- (nullable RTCVideoEncoderQpThresholds *)scalingSettings { return nil; }
- (NSInteger)resolutionAlignment { return 2; }
- (BOOL)applyAlignmentToAllSimulcastLayers { return NO; }
- (BOOL)supportsNativeHandle { return NO; }
@end

@implementation H264VideoEncoderFactory

- (NSArray<RTCVideoCodecInfo *> *)supportedCodecs {
    RTCVideoCodecInfo *h264 = [[RTCVideoCodecInfo alloc]
        initWithName:@"H264"
        parameters:@{
            @"profile-level-id": kProfileLevelId,
            @"packetization-mode": @"1",
            @"level-asymmetry-allowed": @"1"
        }];
    return @[ h264 ];
}

- (nullable id<RTCVideoEncoder>)createEncoder:(RTCVideoCodecInfo *)info {
    if ([info.name caseInsensitiveCompare:@"H264"] != NSOrderedSame) return nil;
    return [[VTEncoder alloc] init];
}

@end

@implementation VP8EncoderFactory {
    RTCDefaultVideoEncoderFactory *_defaultFactory;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _defaultFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    }
    return self;
}

- (NSArray<RTCVideoCodecInfo *> *)supportedCodecs {
    NSMutableArray<RTCVideoCodecInfo *> *out = [NSMutableArray array];
    for (RTCVideoCodecInfo *info in [RTCDefaultVideoEncoderFactory supportedCodecs]) {
        if ([info.name caseInsensitiveCompare:@"VP8"] == NSOrderedSame) {
            [out addObject:info];
        }
    }
    return out;
}

- (nullable id<RTCVideoEncoder>)createEncoder:(RTCVideoCodecInfo *)info {
    if ([info.name caseInsensitiveCompare:@"VP8"] != NSOrderedSame) return nil;
    return [_defaultFactory createEncoder:info];
}

@end
