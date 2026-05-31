#import "DuskVLCRawVideoOutput.h"

#import <CoreVideo/CoreVideo.h>
#import <VLCKit/VLCKit.h>
#import <vlc/vlc.h>
#import <string.h>

@interface VLCMediaPlayer (DuskLibVLCBridge)
@property (nonatomic, readonly) void *libVLCMediaPlayer;
@end

static unsigned DuskVLCSetupVideoFormat(
    void **opaque,
    char *chroma,
    unsigned *width,
    unsigned *height,
    unsigned *pitches,
    unsigned *lines
);
static void DuskVLCCleanupVideoFormat(void *opaque);
static void *DuskVLCLockVideo(void *opaque, void **planes);
static void DuskVLCUnlockVideo(void *opaque, void *picture, void *const *planes);
static void DuskVLCDisplayVideo(void *opaque, void *picture);

@interface DuskVLCRawVideoOutput ()
@property (nonatomic, strong) id<DuskVLCVideoFrameConsumer> frameConsumer;
@property (nonatomic) CVPixelBufferPoolRef pixelBufferPool;
@property (nonatomic) size_t width;
@property (nonatomic) size_t height;
@property (nonatomic) size_t pitch;
@property (nonatomic, readwrite) BOOL isAttached;
@end

@implementation DuskVLCRawVideoOutput

- (instancetype)initWithFrameConsumer:(id<DuskVLCVideoFrameConsumer>)frameConsumer
{
    self = [super init];
    if (self) {
        _frameConsumer = frameConsumer;
    }
    return self;
}

- (void)dealloc
{
    [self releasePixelBufferPool];
}

- (BOOL)attachToPlayer:(VLCMediaPlayer *)player
{
    if (self.isAttached) {
        return YES;
    }

    if (![player respondsToSelector:@selector(libVLCMediaPlayer)]) {
        return NO;
    }

    libvlc_media_player_t *mediaPlayer = (libvlc_media_player_t *)player.libVLCMediaPlayer;
    if (mediaPlayer == NULL) {
        return NO;
    }

    libvlc_video_set_callbacks(
        mediaPlayer,
        DuskVLCLockVideo,
        DuskVLCUnlockVideo,
        DuskVLCDisplayVideo,
        (__bridge void *)self
    );
    libvlc_video_set_format_callbacks(mediaPlayer, DuskVLCSetupVideoFormat, DuskVLCCleanupVideoFormat);

    self.isAttached = YES;
    return YES;
}

- (void)detach
{
    self.isAttached = NO;
}

- (void)releasePixelBufferPool
{
    CVPixelBufferPoolRef pool = NULL;
    @synchronized (self) {
        pool = _pixelBufferPool;
        _pixelBufferPool = NULL;
    }

    if (pool != NULL) {
        CVPixelBufferPoolRelease(pool);
    }
}

- (BOOL)preparePixelBufferPoolWithWidth:(size_t)width height:(size_t)height pitch:(size_t *)pitch
{
    NSDictionary *attributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString *)kCVPixelBufferWidthKey: @(width),
        (NSString *)kCVPixelBufferHeightKey: @(height),
        (NSString *)kCVPixelBufferBytesPerRowAlignmentKey: @64,
        (NSString *)kCVPixelBufferMetalCompatibilityKey: @YES,
        (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CVPixelBufferPoolRef pool = NULL;
    CVReturn poolResult = CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &pool);
    if (poolResult != kCVReturnSuccess || pool == NULL) {
        return NO;
    }

    CVPixelBufferRef sampleBuffer = NULL;
    CVReturn bufferResult = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &sampleBuffer);
    if (bufferResult != kCVReturnSuccess || sampleBuffer == NULL) {
        CVPixelBufferPoolRelease(pool);
        return NO;
    }

    CVPixelBufferLockBaseAddress(sampleBuffer, 0);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(sampleBuffer);
    CVPixelBufferUnlockBaseAddress(sampleBuffer, 0);
    CVPixelBufferRelease(sampleBuffer);

    CVPixelBufferPoolRef oldPool = NULL;
    @synchronized (self) {
        oldPool = _pixelBufferPool;
        _pixelBufferPool = pool;
        self.width = width;
        self.height = height;
        self.pitch = bytesPerRow;
    }

    if (oldPool != NULL) {
        CVPixelBufferPoolRelease(oldPool);
    }

    *pitch = bytesPerRow;
    return YES;
}

- (CVPixelBufferRef)newPixelBuffer
{
    CVPixelBufferPoolRef pool = NULL;
    @synchronized (self) {
        if (_pixelBufferPool != NULL) {
            pool = (CVPixelBufferPoolRef)CFRetain(_pixelBufferPool);
        }
    }

    if (pool == NULL) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &pixelBuffer);
    CVPixelBufferPoolRelease(pool);
    if (result != kCVReturnSuccess || pixelBuffer == NULL) {
        return NULL;
    }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    return pixelBuffer;
}

- (void)finishPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
    if (!self.isAttached || self.frameConsumer == nil) {
        return;
    }

    CFRetain(pixelBuffer);
    [self.frameConsumer duskVLCVideoOutputDidProducePixelBuffer:pixelBuffer];
    CFRelease(pixelBuffer);
}

static unsigned DuskVLCSetupVideoFormat(
    void **opaque,
    char *chroma,
    unsigned *width,
    unsigned *height,
    unsigned *pitches,
    unsigned *lines
) {
    DuskVLCRawVideoOutput *output = (__bridge DuskVLCRawVideoOutput *)(*opaque);
    if (output == nil || width == NULL || height == NULL || pitches == NULL || lines == NULL) {
        return 0;
    }

    memcpy(chroma, "RGBA", 4);

    size_t pitch = (size_t)(*width) * 4;
    if (![output preparePixelBufferPoolWithWidth:*width height:*height pitch:&pitch]) {
        return 0;
    }

    pitches[0] = (unsigned)pitch;
    lines[0] = *height;
    return 4;
}

static void DuskVLCCleanupVideoFormat(void *opaque)
{
    DuskVLCRawVideoOutput *output = (__bridge DuskVLCRawVideoOutput *)opaque;
    [output releasePixelBufferPool];
}

static void *DuskVLCLockVideo(void *opaque, void **planes)
{
    DuskVLCRawVideoOutput *output = (__bridge DuskVLCRawVideoOutput *)opaque;
    CVPixelBufferRef pixelBuffer = [output newPixelBuffer];
    if (pixelBuffer == NULL) {
        return NULL;
    }

    planes[0] = CVPixelBufferGetBaseAddress(pixelBuffer);
    return pixelBuffer;
}

static void DuskVLCUnlockVideo(void *opaque, void *picture, void *const *planes)
{
    if (picture == NULL) {
        return;
    }

    DuskVLCRawVideoOutput *output = (__bridge DuskVLCRawVideoOutput *)opaque;
    [output finishPixelBuffer:(CVPixelBufferRef)picture];
}

static void DuskVLCDisplayVideo(void *opaque, void *picture)
{
    if (picture == NULL) {
        return;
    }

    DuskVLCRawVideoOutput *output = (__bridge DuskVLCRawVideoOutput *)opaque;
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)picture;
    [output displayPixelBuffer:pixelBuffer];
    CVPixelBufferRelease(pixelBuffer);
}

@end
