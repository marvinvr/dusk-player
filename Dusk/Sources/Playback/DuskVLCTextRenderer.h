#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_OSX
#import <VLCKit/VLCKit.h>
#elif TARGET_OS_TV
#import <TVVLCKit/TVVLCKit.h>
#else
#import <MobileVLCKit/MobileVLCKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

/// Sets libvlc `freetype-*` text renderer variables on a media player.
///
/// The video output and its text renderer are children of the libvlc media
/// player object, not of the input, so per-media `:freetype-…` options never
/// reach them. VLCKit 3.x's own text renderer setters only cover font, size,
/// colour and bold; everything else (opacity, background, outline, shadow) has
/// to be created as an inheritable variable on the player itself. The renderer
/// reads them when the next media opens. Each call returns NO when VLCKit no
/// longer exposes the player handle.
@interface DuskVLCTextRenderer : NSObject

+ (BOOL)setInteger:(int64_t)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player;
+ (BOOL)setFloat:(float)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player;
+ (BOOL)setString:(NSString *)value forOption:(NSString *)option onPlayer:(VLCMediaPlayer *)player;

/// Sets libvlc's `sub-margin`, raising subtitles by that many render pixels.
/// Unlike the `freetype-*` variables this takes effect on the running video
/// output: the vout is a child of the player and listens to its own copy, and
/// the player's copy is what a vout created later inherits.
+ (BOOL)setSubtitleMargin:(int32_t)margin onPlayer:(VLCMediaPlayer *)player NS_SWIFT_NAME(setSubtitleMargin(_:on:));

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
