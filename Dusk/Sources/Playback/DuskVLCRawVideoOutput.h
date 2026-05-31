#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VLCKit/VLCKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol DuskVLCVideoFrameConsumer <NSObject>
- (void)duskVLCVideoOutputDidProducePixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@interface DuskVLCRawVideoOutput : NSObject

@property (nonatomic, readonly) BOOL isAttached;

- (instancetype)initWithFrameConsumer:(id<DuskVLCVideoFrameConsumer>)frameConsumer NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)attachToPlayer:(VLCMediaPlayer *)player;
- (void)detach;

@end

NS_ASSUME_NONNULL_END
