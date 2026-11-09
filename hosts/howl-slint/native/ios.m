// Public Apple APIs only. This translation unit is compiled with ARC.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#include <stdlib.h>
#include <string.h>

// Caller owns the returned UTF-8 string, released by howl_ios_free_string.
char *howl_ios_settings_directory(void) {
    @autoreleasepool {
        NSURL *url = [[NSFileManager defaultManager]
            URLForDirectory:NSApplicationSupportDirectory
            inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:NULL];
        const char *path = url.fileSystemRepresentation;
        return path ? strdup(path) : NULL;
    }
}

char *howl_ios_font_path(void) {
    @autoreleasepool {
        CTFontRef font = CTFontCreateWithName(CFSTR("Courier"), 16, NULL);
        if (!font) return NULL;
        CFTypeRef attribute = CTFontCopyAttribute(font, kCTFontURLAttribute);
        CFRelease(font);
        if (!attribute) return NULL;
        char *path = NULL;
        if (CFGetTypeID(attribute) == CFURLGetTypeID()) {
            NSURL *url = (__bridge NSURL *)attribute;
            // The native renderer opens face zero. Verify that face rather than
            // pretending the CoreText-selected collection index crosses the ABI.
            CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
            if (descriptors && CFArrayGetCount(descriptors) > 0) {
                CTFontDescriptorRef first = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0);
                CTFontRef face = CTFontCreateWithFontDescriptor(first, 16, NULL);
                if (face && (CTFontGetSymbolicTraits(face) & kCTFontMonoSpaceTrait)) {
                    const char *bytes = url.fileSystemRepresentation;
                    if (bytes) path = strdup(bytes);
                }
                if (face) CFRelease(face);
            }
            if (descriptors) CFRelease(descriptors);
        }
        CFRelease(attribute);
        return path;
    }
}

void howl_ios_free_string(char *value) { free(value); }

typedef void (*HowlSuspendCallback)(void *);
@interface HowlLifecycleObserver : NSObject
@property(nonatomic, assign) HowlSuspendCallback callback;
@property(nonatomic, assign) void *context;
- (void)suspend:(NSNotification *)notification;
@end
@implementation HowlLifecycleObserver
- (void)suspend:(NSNotification *)notification {
    (void)notification;
    // UIKit delivers lifecycle notifications on the main/UI thread. Never queue
    // the detach behind app suspension; release the attachment synchronously.
    NSCAssert([NSThread isMainThread], @"Howl lifecycle requires the UI thread");
    self.callback(self.context);
}
@end

void *howl_ios_observe_lifecycle(HowlSuspendCallback callback, void *context) {
    NSCAssert([NSThread isMainThread], @"Howl lifecycle requires the UI thread");
    HowlLifecycleObserver *observer = [HowlLifecycleObserver new];
    observer.callback = callback;
    observer.context = context;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in @[
        UIApplicationWillResignActiveNotification,
        UIApplicationDidEnterBackgroundNotification,
        UISceneWillDeactivateNotification,
        UISceneDidEnterBackgroundNotification,
        UISceneDidDisconnectNotification
    ]) {
        [center addObserver:observer selector:@selector(suspend:) name:name object:nil];
    }
    return (__bridge_retained void *)observer;
}

void howl_ios_remove_lifecycle(void *handle) {
    NSCAssert([NSThread isMainThread], @"Howl lifecycle requires the UI thread");
    HowlLifecycleObserver *observer = (__bridge_transfer HowlLifecycleObserver *)handle;
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
}
