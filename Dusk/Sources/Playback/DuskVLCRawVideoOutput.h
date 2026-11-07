#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@protocol DuskVLCVideoFrameConsumer <NSObject>
- (void)duskVLCVideoOutputDidProducePixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@interface DuskVLCRawVideoOutput : NSObject

@property (nonatomic, readonly) BOOL isAttached;
/// Opt-in for sample-buffer PiP with captions. Adds a full-frame resize to
/// force late SPU blending; never enable for ordinary Metal enhancement.
@property (nonatomic) BOOL requiresLateSubtitleBlending;

- (instancetype)initWithFrameConsumer:(id<DuskVLCVideoFrameConsumer>)frameConsumer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)attachToPlayer:(VLCMediaPlayer *)player;
- (void)detach;

@end

NS_ASSUME_NONNULL_END
