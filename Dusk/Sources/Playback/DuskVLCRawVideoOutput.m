#import "DuskVLCRawVideoOutput.h"

#import <CoreVideo/CoreVideo.h>
#import <TargetConditionals.h>
#if TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif
#import <vlc/vlc.h>
#import <stdlib.h>
#import <string.h>

// VLCKit 3.x keeps the raw libvlc player handle behind the private
// `playerInstance` accessor (verified against the vendored 3.7.3 binary's
// method list). Guarded by respondsToSelector below so a future VLCKit that
// removes it degrades to "enhancement unavailable" instead of crashing.
@interface VLCMediaPlayer (DuskLibVLCBridge)
@property (nonatomic, readonly) libvlc_media_player_t *playerInstance;
@end

/// Stable rendezvous point between libvlc's video callbacks and the output.
///
/// libvlc stores the `opaque` we register as a bare address on the media player
/// and re-reads it every time it opens a video output. libvlc 3.x has no API to
/// unregister, so passing `(__bridge void *)self` would leave it holding an
/// unowned pointer that dangles the instant the output is released — and the
/// video thread can open an output at any moment, including during teardown.
///
/// This handle is deliberately immortal (one ~16 byte object per output,
/// retained forever in `-initWithFrameConsumer:`) so that the registered
/// address is always safe to dereference. The weak `output` resolves to nil
/// once the real object is gone, which turns a use-after-free into a video
/// output that simply declines to open.
@interface DuskVLCOutputHandle : NSObject
@property (weak) DuskVLCRawVideoOutput *output;
@end

@implementation DuskVLCOutputHandle
@end

/// Everything one libvlc video output needs, owned for exactly as long as that
/// output lives.
///
/// libvlc hands the format callback an [IN/OUT] opaque, so `setup` swaps the
/// process-wide handle for one of these and gets it back in every subsequent
/// lock/unlock/display/cleanup. libvlc's vmem module pairs setup with cleanup
/// around the video output's Open/Close, which is what makes the pool's
/// lifetime match the decoder's: it can no longer be torn down out from under a
/// decode that is already in flight.
typedef struct DuskVLCVideoContext {
    CVPixelBufferPoolRef pool;
    /// Retained. libvlc keeps decoding into this context after the app has
    /// dropped its own reference to the output, so the context owns one.
    CFTypeRef output;
    /// Handed to libvlc whenever the pool cannot vend a buffer, sized to the
    /// pitch * lines geometry reported to it. See DuskVLCLockVideo for why this
    /// must always exist.
    void *fallbackPlane;
} DuskVLCVideoContext;

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
@property (nonatomic, readwrite) BOOL isAttached;
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end

@implementation DuskVLCRawVideoOutput {
    /// See DuskVLCOutputHandle. Intentionally never released.
    void *_handleRef;
}

- (instancetype)initWithFrameConsumer:(id<DuskVLCVideoFrameConsumer>)frameConsumer
{
    self = [super init];
    if (self) {
        _frameConsumer = frameConsumer;
        DuskVLCOutputHandle *handle = [[DuskVLCOutputHandle alloc] init];
        handle.output = self;
        _handleRef = (__bridge_retained void *)handle;
    }
    return self;
}

- (BOOL)attachToPlayer:(VLCMediaPlayer *)player
{
    if (self.isAttached) {
        return YES;
    }

    if (![player respondsToSelector:@selector(playerInstance)]) {
        return NO;
    }

    libvlc_media_player_t *mediaPlayer = player.playerInstance;
    if (mediaPlayer == NULL) {
        return NO;
    }

    // Format callbacks first: it is libvlc_video_set_callbacks that switches the
    // player over to the vmem output, so registering in the other order leaves a
    // window where a video output could open with no format callback, keep the
    // handle as its opaque, and hand it to DuskVLCLockVideo as a video context.
    libvlc_video_set_format_callbacks(mediaPlayer, DuskVLCSetupVideoFormat, DuskVLCCleanupVideoFormat);
    libvlc_video_set_callbacks(
        mediaPlayer,
        DuskVLCLockVideo,
        DuskVLCUnlockVideo,
        DuskVLCDisplayVideo,
        _handleRef
    );

    self.isAttached = YES;
    return YES;
}

/// Stops frame delivery. This intentionally does not unregister the libvlc
/// callbacks: libvlc 3.x offers no way to undo `libvlc_video_set_callbacks`
/// (it also pins the player to the vmem output), and a video output that is
/// already decoding keeps its own copy of them regardless. Safety therefore
/// comes from the callbacks staying valid forever rather than from revoking
/// them — see DuskVLCOutputHandle and DuskVLCVideoContext.
- (void)detach
{
    self.isAttached = NO;
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

@end

/// Creates the pool a single video output feeds from, and reports the row
/// stride libvlc must decode at. CoreVideo pads rows to its own alignment, so
/// the only authoritative stride is the one on a buffer the pool actually
/// vends — probe one and discard it.
static BOOL DuskVLCMakePixelBufferPool(
    size_t width,
    size_t height,
    CVPixelBufferPoolRef *outPool,
    size_t *outPitch
) {
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

    CVPixelBufferRef probe = NULL;
    CVReturn bufferResult = CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &probe);
    if (bufferResult != kCVReturnSuccess || probe == NULL) {
        CVPixelBufferPoolRelease(pool);
        return NO;
    }

    CVPixelBufferLockBaseAddress(probe, 0);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(probe);
    CVPixelBufferUnlockBaseAddress(probe, 0);
    CVPixelBufferRelease(probe);

    if (bytesPerRow < width * 4) {
        CVPixelBufferPoolRelease(pool);
        return NO;
    }

    *outPool = pool;
    *outPitch = bytesPerRow;
    return YES;
}

static unsigned DuskVLCSetupVideoFormat(
    void **opaque,
    char *chroma,
    unsigned *width,
    unsigned *height,
    unsigned *pitches,
    unsigned *lines
) {
    if (opaque == NULL || chroma == NULL || width == NULL || height == NULL ||
        pitches == NULL || lines == NULL) {
        return 0;
    }

    DuskVLCOutputHandle *handle = (__bridge DuskVLCOutputHandle *)(*opaque);
    DuskVLCRawVideoOutput *output = handle.output;
    if (output == nil || *width == 0 || *height == 0) {
        return 0;
    }

    CVPixelBufferPoolRef pool = NULL;
    size_t pitch = 0;
    if (!DuskVLCMakePixelBufferPool(*width, *height, &pool, &pitch)) {
        return 0;
    }

    // libvlc writes pitch * lines bytes per plane, so the fallback has to cover
    // exactly the geometry reported below. 64 matches the pool's row alignment
    // and clears libvlc's documented 32-byte minimum for pixel planes.
    size_t planeSize = pitch * (size_t)(*height);
    void *fallbackPlane = NULL;
    if (posix_memalign(&fallbackPlane, 64, planeSize) != 0 || fallbackPlane == NULL) {
        CVPixelBufferPoolRelease(pool);
        return 0;
    }

    DuskVLCVideoContext *context = calloc(1, sizeof(DuskVLCVideoContext));
    if (context == NULL) {
        free(fallbackPlane);
        CVPixelBufferPoolRelease(pool);
        return 0;
    }

    context->pool = pool;
    context->output = CFBridgingRetain(output);
    context->fallbackPlane = fallbackPlane;

    memcpy(chroma, "RGBA", 4);
    pitches[0] = (unsigned)pitch;
    lines[0] = *height;
    *opaque = context;
    return 4;
}

static void DuskVLCCleanupVideoFormat(void *opaque)
{
    DuskVLCVideoContext *context = (DuskVLCVideoContext *)opaque;
    if (context == NULL) {
        return;
    }

    if (context->pool != NULL) {
        CVPixelBufferPoolRelease(context->pool);
    }
    if (context->output != NULL) {
        CFRelease(context->output);
    }
    free(context->fallbackPlane);
    free(context);
}

static void *DuskVLCLockVideo(void *opaque, void **planes)
{
    DuskVLCVideoContext *context = (DuskVLCVideoContext *)opaque;
    if (context == NULL || planes == NULL) {
        return NULL;
    }

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = CVPixelBufferPoolCreatePixelBuffer(NULL, context->pool, &pixelBuffer);
    if (result == kCVReturnSuccess && pixelBuffer != NULL) {
        if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) == kCVReturnSuccess) {
            void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
            if (base != NULL) {
                planes[0] = base;
                return pixelBuffer;
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        }
        CVPixelBufferRelease(pixelBuffer);
    }

    // There is no way to refuse a frame here. libvlc decodes straight into
    // planes[0] and ignores this return value (it is only an identifier for the
    // unlock/display callbacks), so returning without setting the plane lets it
    // memcpy a full picture over whatever address the uninitialized pointer
    // happens to hold — which corrupts the heap with pixel data. Point it at the
    // scratch plane instead and drop the frame in DuskVLCDisplayVideo.
    planes[0] = context->fallbackPlane;
    return NULL;
}

static void DuskVLCUnlockVideo(void *opaque, void *picture, void *const *planes)
{
    (void)opaque;
    (void)planes;
    if (picture == NULL) {
        return;
    }

    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0);
}

static void DuskVLCDisplayVideo(void *opaque, void *picture)
{
    if (picture == NULL) {
        return;
    }

    DuskVLCVideoContext *context = (DuskVLCVideoContext *)opaque;
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)picture;
    if (context != NULL && context->output != NULL) {
        [(__bridge DuskVLCRawVideoOutput *)context->output displayPixelBuffer:pixelBuffer];
    }
    CVPixelBufferRelease(pixelBuffer);
}
