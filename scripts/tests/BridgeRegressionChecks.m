#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>

#import "../../DisplayLoom/Bridge/VSCGVirtualDisplayBridge.h"

static Class VSCGTestClassFromString(NSString *name);
static bool VSCGTestDisplayIsOnline(CGDirectDisplayID displayID);
static CFArrayRef VSCGTestCopyAllDisplayModes(CGDirectDisplayID displayID, CFDictionaryRef options);
static size_t VSCGTestModeGetPixelWidth(CGDisplayModeRef mode);
static size_t VSCGTestModeGetPixelHeight(CGDisplayModeRef mode);
static double VSCGTestModeGetRefreshRate(CGDisplayModeRef mode);
static bool VSCGTestDisplayIsInMirrorSet(CGDirectDisplayID displayID);
static CGDirectDisplayID VSCGTestDisplayMirrorsDisplay(CGDirectDisplayID displayID);
static CGError VSCGTestSetDisplayMode(CGDirectDisplayID displayID,
                                    CGDisplayModeRef mode,
                                    CFDictionaryRef options);

// Compile the production calls with fake runtime lookup and display functions.
// This executable is separate from XCTest and cannot allocate or change a real display.
#define NSClassFromString VSCGTestClassFromString
#define CGDisplayIsOnline VSCGTestDisplayIsOnline
#define CGDisplayCopyAllDisplayModes VSCGTestCopyAllDisplayModes
#define CGDisplayModeGetPixelWidth VSCGTestModeGetPixelWidth
#define CGDisplayModeGetPixelHeight VSCGTestModeGetPixelHeight
#define CGDisplayModeGetRefreshRate VSCGTestModeGetRefreshRate
#define CGDisplayIsInMirrorSet VSCGTestDisplayIsInMirrorSet
#define CGDisplayMirrorsDisplay VSCGTestDisplayMirrorsDisplay
#define CGDisplaySetDisplayMode VSCGTestSetDisplayMode
// The included implementation is not a header with complete nullability annotations.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#include "../../DisplayLoom/Bridge/VSCGVirtualDisplayBridge.m"
#pragma clang diagnostic pop
#undef NSClassFromString
#undef CGDisplayIsOnline
#undef CGDisplayCopyAllDisplayModes
#undef CGDisplayModeGetPixelWidth
#undef CGDisplayModeGetPixelHeight
#undef CGDisplayModeGetRefreshRate
#undef CGDisplayIsInMirrorSet
#undef CGDisplayMirrorsDisplay
#undef CGDisplaySetDisplayMode

typedef NS_ENUM(NSUInteger, VSCGTestInitResult) {
    VSCGTestInitSelf,
    VSCGTestInitNil,
    VSCGTestInitReplacement,
};

typedef NS_ENUM(NSUInteger, VSCGTestMirrorState) {
    VSCGTestUnmirrored,
    VSCGTestMirrorSecondary,
    VSCGTestMirrorPrimary,
};

static void VSCGTestRequire(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL bridge: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

@interface VSCGTestDescriptor : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t vendorID;
@property(nonatomic) uint32_t productID;
@property(nonatomic) uint32_t serialNumber;
@property(nonatomic) uint32_t maxPixelsWide;
@property(nonatomic) uint32_t maxPixelsHigh;
@property(nonatomic, strong) dispatch_queue_t dispatchQueue;
@property(nonatomic, copy) void (^terminationHandler)(id, id);
@end

@implementation VSCGTestDescriptor
@end

@interface VSCGTestSettings : NSObject <VSCGPrivateDisplaySettingsSelectors>
@property(nonatomic, copy) NSArray *modes;
@property(nonatomic) uint32_t hiDPI;
@end

@implementation VSCGTestSettings
@end

@interface VSCGTestMode : NSObject <VSCGPrivateDisplayModeSelectors>
@property(nonatomic) uint32_t width;
@property(nonatomic) uint32_t height;
@property(nonatomic) double refreshRate;
@end

@interface VSCGTestDisplay : NSObject <VSCGPrivateDisplaySelectors>
@property(nonatomic, strong) VSCGTestDescriptor *descriptor;
@property(nonatomic, strong) VSCGTestSettings *settings;
@end

static VSCGTestInitResult modeInitResult;
static VSCGTestInitResult displayInitResult;
static NSUInteger modeAllocations;
static NSUInteger modeDeallocations;
static NSUInteger displayAllocations;
static NSUInteger displayDeallocations;
static __weak VSCGTestMode *allocatedMode;
static __weak VSCGTestMode *returnedMode;
static __weak VSCGTestDisplay *allocatedDisplay;
static __weak VSCGTestDisplay *returnedDisplay;
static VSCGTestMirrorState mirrorState;
static NSUInteger modeWrites;
static NSArray<VSCGTestMode *> *availableModes;
static double lastWrittenRefreshRate;
static NSUInteger terminationCalls;
static const CGDirectDisplayID testDisplayID = 424242;

@implementation VSCGTestMode

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    modeAllocations += 1;
    return [super allocWithZone:zone];
}

- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate {
    self = [super init];
    allocatedMode = self;
    if (modeInitResult == VSCGTestInitNil) {
        self = nil;
        return nil;
    }
    if (modeInitResult == VSCGTestInitReplacement) {
        self = [[VSCGTestMode alloc] init];
    }
    self.width = width;
    self.height = height;
    self.refreshRate = refreshRate;
    returnedMode = self;
    return self;
}

- (void)dealloc {
    modeDeallocations += 1;
}

@end

@implementation VSCGTestDisplay

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    displayAllocations += 1;
    return [super allocWithZone:zone];
}

- (instancetype)initWithDescriptor:(id)descriptor {
    self = [super init];
    allocatedDisplay = self;
    if (displayInitResult == VSCGTestInitNil) {
        self = nil;
        return nil;
    }
    if (displayInitResult == VSCGTestInitReplacement) {
        self = [[VSCGTestDisplay alloc] init];
    }
    self.descriptor = descriptor;
    returnedDisplay = self;
    return self;
}

- (BOOL)applySettings:(id)settings {
    self.settings = settings;
    VSCGTestRequire(self.settings.modes.count == 1, @"Production must supply the requested mode");
    VSCGTestRequire(self.settings.modes.firstObject == returnedMode,
                    @"Settings must own the object returned by the mode initializer");
    VSCGTestRequire(returnedMode.width == 1920 && returnedMode.height == 1080 &&
                        returnedMode.refreshRate == 60,
                    @"Production must pass all mode initializer arguments");
    VSCGTestRequire([self.descriptor.name isEqualToString:@"Bridge Test"],
                    @"Production must pass the display descriptor");
    return YES;
}

- (uint32_t)displayID {
    return testDisplayID;
}

- (void)dealloc {
    displayDeallocations += 1;
}

@end

static Class VSCGTestClassFromString(NSString *name) {
    if ([name isEqualToString:@"CGVirtualDisplayDescriptor"]) {
        return VSCGTestDescriptor.class;
    }
    if ([name isEqualToString:@"CGVirtualDisplaySettings"]) {
        return VSCGTestSettings.class;
    }
    if ([name isEqualToString:@"CGVirtualDisplayMode"]) {
        return VSCGTestMode.class;
    }
    if ([name isEqualToString:@"CGVirtualDisplay"]) {
        return VSCGTestDisplay.class;
    }
    VSCGTestRequire(NO, @"Unexpected production class lookup");
    return Nil;
}

static bool VSCGTestDisplayIsOnline(CGDirectDisplayID displayID) {
    VSCGTestRequire(displayID == testDisplayID, @"Only the fake display may be queried");
    return true;
}

static CFArrayRef VSCGTestCopyAllDisplayModes(CGDirectDisplayID displayID,
                                             __unused CFDictionaryRef options) {
    VSCGTestRequire(displayID == testDisplayID, @"Only fake modes may be queried");
    VSCGTestRequire(returnedMode != nil, @"The fake mode must remain owned");
    return (__bridge_retained CFArrayRef)(availableModes ?: @[returnedMode]);
}

static size_t VSCGTestModeGetPixelWidth(CGDisplayModeRef mode) {
    return ((__bridge VSCGTestMode *)mode).width;
}

static size_t VSCGTestModeGetPixelHeight(CGDisplayModeRef mode) {
    return ((__bridge VSCGTestMode *)mode).height;
}

static double VSCGTestModeGetRefreshRate(CGDisplayModeRef mode) {
    return ((__bridge VSCGTestMode *)mode).refreshRate;
}

static bool VSCGTestDisplayIsInMirrorSet(CGDirectDisplayID displayID) {
    VSCGTestRequire(displayID == testDisplayID, @"Only fake mirror membership may be queried");
    return mirrorState != VSCGTestUnmirrored;
}

static CGDirectDisplayID VSCGTestDisplayMirrorsDisplay(CGDirectDisplayID displayID) {
    VSCGTestRequire(displayID == testDisplayID, @"Only fake mirror identity may be queried");
    return mirrorState == VSCGTestMirrorSecondary ? 99 : kCGNullDirectDisplay;
}

static CGError VSCGTestSetDisplayMode(CGDirectDisplayID displayID,
                                    CGDisplayModeRef mode,
                                    __unused CFDictionaryRef options) {
    VSCGTestRequire(displayID == testDisplayID, @"Only the fake display may be written");
    VSCGTestRequire(availableModes ? [availableModes containsObject:(__bridge id)mode]
                                   : (__bridge id)mode == returnedMode,
                    @"The selected mode must match an available mode");
    lastWrittenRefreshRate = VSCGTestModeGetRefreshRate(mode);
    modeWrites += 1;
    return kCGErrorSuccess;
}

static void VSCGTestReset(VSCGTestInitResult modeResult, VSCGTestInitResult displayResult) {
    VSCGTestRequire(modeAllocations == modeDeallocations, @"Previous fake modes must be released");
    VSCGTestRequire(displayAllocations == displayDeallocations,
                    @"Previous fake displays must be released");
    modeInitResult = modeResult;
    displayInitResult = displayResult;
    modeAllocations = 0;
    modeDeallocations = 0;
    displayAllocations = 0;
    displayDeallocations = 0;
    mirrorState = VSCGTestUnmirrored;
    modeWrites = 0;
    availableModes = nil;
    lastWrittenRefreshRate = 0;
    terminationCalls = 0;
}

static VSCGVirtualDisplayHandle *VSCGTestCreateHandle(NSError **error) {
    VSCGVirtualDisplayModeSpec *mode = [[VSCGVirtualDisplayModeSpec alloc] initWithWidth:1920
                                                                               height:1080
                                                                          refreshRate:60];
    return [VSCGVirtualDisplayHandle createWithName:@"Bridge Test"
                                         vendorID:1
                                        productID:2
                                     serialNumber:3
                                         maxWidth:1920
                                        maxHeight:1080
                                            modes:@[mode]
                               terminationHandler:^{ terminationCalls += 1; }
                                            error:error];
}

static void VSCGTestInitializerOwnership(VSCGTestInitResult modeResult,
                                        VSCGTestInitResult displayResult) {
    VSCGTestReset(modeResult, displayResult);
    @autoreleasepool {
        NSError *error = nil;
        VSCGVirtualDisplayHandle *handle = VSCGTestCreateHandle(&error);
        BOOL succeeds = modeResult != VSCGTestInitNil && displayResult != VSCGTestInitNil;
        if (succeeds) {
            VSCGTestRequire(handle != nil && error == nil, @"Valid fake initializers must succeed");
            VSCGTestRequire(handle.displayID == testDisplayID && handle.valid,
                            @"The handle must own the initialized fake display");
            VSCGTestRequire(returnedMode != nil && returnedDisplay != nil,
                            @"Initialized objects must stay alive while owned by the handle");
            VSCGTestRequire((allocatedMode == returnedMode) == (modeResult == VSCGTestInitSelf),
                            @"The mode initializer may return self or a replacement");
            VSCGTestRequire((allocatedDisplay == returnedDisplay) ==
                                (displayResult == VSCGTestInitSelf),
                            @"The display initializer may return self or a replacement");
            [handle invalidate];
            [handle invalidate];
            VSCGTestRequire(returnedDisplay == nil, @"Invalidation must release the display owner");
        } else {
            VSCGVirtualDisplayErrorCode expected = modeResult == VSCGTestInitNil
                ? VSCGVirtualDisplayErrorInvalidConfiguration : VSCGVirtualDisplayErrorCreationFailed;
            VSCGTestRequire(handle == nil && [error.domain isEqual:VSCGVirtualDisplayErrorDomain] &&
                                error.code == expected,
                            @"A nil initializer must return the production bridge error");
        }
        if (modeResult != VSCGTestInitSelf) {
            VSCGTestRequire(allocatedMode == nil, @"A consumed mode receiver must not stay retained");
        }
        if (displayResult != VSCGTestInitSelf) {
            VSCGTestRequire(allocatedDisplay == nil,
                            @"A consumed display receiver must not stay retained");
        }
    }
    NSUInteger expectedModes = modeResult == VSCGTestInitReplacement ? 2 : 1;
    NSUInteger expectedDisplays = modeResult == VSCGTestInitNil ? 0
        : (displayResult == VSCGTestInitReplacement ? 2 : 1);
    VSCGTestRequire(modeAllocations == expectedModes && modeDeallocations == expectedModes,
                    @"All allocated modes must be released exactly once");
    VSCGTestRequire(displayAllocations == expectedDisplays &&
                        displayDeallocations == expectedDisplays,
                    @"All allocated displays must be released exactly once");
    VSCGTestRequire(returnedMode == nil && returnedDisplay == nil,
                    @"No initialized object may escape cleanup");
    VSCGTestRequire(terminationCalls == 0, @"Cleanup must not invoke the client callback");
}

static void VSCGTestMirrorGuard(VSCGTestMirrorState state) {
    VSCGTestReset(VSCGTestInitSelf, VSCGTestInitSelf);
    @autoreleasepool {
        NSError *error = nil;
        VSCGVirtualDisplayHandle *handle = VSCGTestCreateHandle(&error);
        VSCGTestRequire(handle != nil && error == nil, @"Fake creation must succeed");
        mirrorState = state;
        VSCGTestRequire(VSCGTestDisplayIsInMirrorSet(handle.displayID) ==
                            (state != VSCGTestUnmirrored),
                        @"Mirror membership must include both primary and secondary displays");
        CGDirectDisplayID source = VSCGTestDisplayMirrorsDisplay(handle.displayID);
        VSCGTestRequire((source != kCGNullDirectDisplay) == (state == VSCGTestMirrorSecondary),
                        @"Mirror primaries have no mirror source identity");
        BOOL changed = [handle setModeWithWidth:1920 height:1080 refreshRate:60 error:&error];
        if (state == VSCGTestUnmirrored) {
            VSCGTestRequire(changed && error == nil && modeWrites == 1,
                            @"An unmirrored display must allow the mode write");
        } else {
            VSCGTestRequire(!changed && error.code == VSCGVirtualDisplayErrorInvalidConfiguration &&
                                [error.domain isEqual:VSCGVirtualDisplayErrorDomain],
                            @"Both mirror secondaries and primaries must reject mode writes");
            VSCGTestRequire(modeWrites == 0, @"A mirror-set member must never reach the mode write");
        }
        [handle invalidate];
    }
    VSCGTestRequire(modeAllocations == modeDeallocations &&
                        displayAllocations == displayDeallocations,
                    @"Mirror checks must release every fake object");
}

static void VSCGTestRefreshRateSelection(void) {
    VSCGTestReset(VSCGTestInitSelf, VSCGTestInitSelf);
    @autoreleasepool {
        NSError *error = nil;
        VSCGVirtualDisplayHandle *handle = VSCGTestCreateHandle(&error);
        VSCGTestRequire(handle != nil && error == nil, @"Fake creation must succeed");
        VSCGTestMode *standard = returnedMode;
        VSCGTestMode *low = [[VSCGTestMode alloc] initWithWidth:1920 height:1080 refreshRate:30];
        // Place 60 Hz first so a resolution-only match would select the wrong rate.
        availableModes = @[standard, low];
        for (NSNumber *rate in @[@30, @60, @30]) {
            BOOL changed = [handle setModeWithWidth:1920 height:1080
                                       refreshRate:rate.doubleValue error:&error];
            VSCGTestRequire(changed && error == nil && lastWrittenRefreshRate == rate.doubleValue,
                            @"Mode selection must match both resolution and refresh rate");
        }
        NSUInteger successfulWrites = modeWrites;
        standard.refreshRate = 0;
        low.refreshRate = 0;
        for (NSNumber *rate in @[@30, @60]) {
            error = nil;
            BOOL changed = [handle setModeWithWidth:1920 height:1080
                                       refreshRate:rate.doubleValue error:&error];
            VSCGTestRequire(!changed && error.code == VSCGVirtualDisplayErrorModeUnavailable &&
                                modeWrites == successfulWrites,
                            @"An unknown reported rate must not silently select a different mode");
        }
        availableModes = nil;
        [handle invalidate];
    }
    VSCGTestRequire(modeAllocations == modeDeallocations &&
                        displayAllocations == displayDeallocations,
                    @"Refresh-rate checks must release every fake object");
}

int main(void) {
    for (VSCGTestInitResult modeResult = VSCGTestInitSelf;
         modeResult <= VSCGTestInitReplacement; modeResult += 1) {
        for (VSCGTestInitResult displayResult = VSCGTestInitSelf;
             displayResult <= VSCGTestInitReplacement; displayResult += 1) {
            VSCGTestInitializerOwnership(modeResult, displayResult);
        }
    }
    VSCGTestMirrorGuard(VSCGTestUnmirrored);
    VSCGTestMirrorGuard(VSCGTestMirrorSecondary);
    VSCGTestMirrorGuard(VSCGTestMirrorPrimary);
    VSCGTestRefreshRateSelection();
    puts("PASS bridge: initializer ownership, mirror guards, and exact refresh rates (fake displays only)");
    return EXIT_SUCCESS;
}
