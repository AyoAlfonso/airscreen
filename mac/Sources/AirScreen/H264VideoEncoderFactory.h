#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

/// Factory that advertises a single constrained-baseline H.264 profile and
/// produces frames with a VideoToolbox hardware encoder.
@interface H264VideoEncoderFactory : NSObject <RTCVideoEncoderFactory>
@end

/// Advertises only VP8 so a fallback cannot silently negotiate H.264 again.
@interface VP8EncoderFactory : NSObject <RTCVideoEncoderFactory>
@end

NS_ASSUME_NONNULL_END
