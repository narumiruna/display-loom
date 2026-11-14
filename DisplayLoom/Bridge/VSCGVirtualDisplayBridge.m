#import "VSCGVirtualDisplayBridge.h"

#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

@protocol VSCGPrivateDisplayDescriptorSelectors <NSObject>
- (void)setVendorID:(uint32_t)value;
- (void)setProductID:(uint32_t)value;
- (void)setSerialNumber:(uint32_t)value;
- (void)setSerialNum:(uint32_t)value;
- (void)setMaxPixelsWide:(uint32_t)value;
- (void)setMaxPixelsHigh:(uint32_t)value;
- (void)setSizeInMillimeters:(CGSize)value;
- (void)setRedPrimary:(CGPoint)value;
- (void)setGreenPrimary:(CGPoint)value;
- (void)setBluePrimary:(CGPoint)value;
- (void)setWhitePoint:(CGPoint)value;
- (void)setDispatchQueue:(dispatch_queue_t)value;
- (void)setQueue:(dispatch_queue_t)value;
- (void)setTerminationHandler:(id)value;
@end

@protocol VSCGPrivateDisplaySettingsSelectors <NSObject>
- (void)setModes:(NSArray *)value;
- (void)setHiDPI:(uint32_t)value;
@end

@protocol VSCGPrivateDisplayModeSelectors <NSObject>
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@protocol VSCGPrivateDisplaySelectors <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
- (uint32_t)displayID;
@end

NSErrorDomain const VSCGVirtualDisplayErrorDomain = @"dev.narumi.DisplayLoom.CGVirtualDisplay";

static NSError *VSCGMakeError(VSCGVirtualDisplayErrorCode code, NSString *description) {
    return [NSError errorWithDomain:VSCGVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL VSCGClassHasInstanceSelector(Class cls, SEL selector) {
    return cls != Nil && class_getInstanceMethod(cls, selector) != NULL;
}

static void VSCGSendUInt32(id target, SEL selector, uint32_t value) {
    ((void (*)(id, SEL, uint32_t))objc_msgSend)(target, selector, value);
}

static uint32_t VSCGGetUInt32(id target, SEL selector) {
    return ((uint32_t (*)(id, SEL))objc_msgSend)(target, selector);
}

static void VSCGSendObject(id target, SEL selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
}

static void VSCGSendSize(id target, SEL selector, CGSize value) {
    ((void (*)(id, SEL, CGSize))objc_msgSend)(target, selector, value);
}

static void VSCGSendPoint(id target, SEL selector, CGPoint value) {
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(target, selector, value);
}

@interface VSCGTerminationState : NSObject
@property(nonatomic, copy, nullable) VSCGVirtualDisplayTerminationHandler handler;
@property(nonatomic) BOOL cancelled;
- (void)invoke;
- (void)cancel;
@end

@implementation VSCGTerminationState

- (void)invoke {
    VSCGVirtualDisplayTerminationHandler handler = nil;
    @synchronized (self) {
        if (!self.cancelled) {
            handler = self.handler;
        }
    }
    if (handler != nil) {
        handler();
    }
}

- (void)cancel {
    @synchronized (self) {
        self.cancelled = YES;
        self.handler = nil;
    }
}

@end

@implementation VSCGVirtualDisplayModeSpec

- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate {
    self = [super init];
    if (self != nil) {
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}

@end

@interface VSCGVirtualDisplayHandle () {
    id _privateDisplay;
    VSCGTerminationState *_terminationState;
    CGDirectDisplayID _displayID;
}
- (instancetype)initWithPrivateDisplay:(id)privateDisplay
                              displayID:(CGDirectDisplayID)displayID
                       terminationState:(VSCGTerminationState *)terminationState;
@end

@implementation VSCGVirtualDisplayHandle

+ (BOOL)isAPIAvailable {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    if (descriptorClass == Nil || settingsClass == Nil || modeClass == Nil || displayClass == Nil) {
        return NO;
    }

    BOOL descriptorAvailable =
        VSCGClassHasInstanceSelector(descriptorClass, @selector(init)) &&
        VSCGClassHasInstanceSelector(descriptorClass, @selector(setName:)) &&
        VSCGClassHasInstanceSelector(descriptorClass, @selector(setVendorID:)) &&
        VSCGClassHasInstanceSelector(descriptorClass, @selector(setProductID:)) &&
        VSCGClassHasInstanceSelector(descriptorClass, @selector(setMaxPixelsWide:)) &&
        VSCGClassHasInstanceSelector(descriptorClass, @selector(setMaxPixelsHigh:)) &&
        VSCGClassHasInstanceSelector(descriptorClass, @selector(setTerminationHandler:)) &&
        (VSCGClassHasInstanceSelector(descriptorClass, @selector(setSerialNumber:)) ||
         VSCGClassHasInstanceSelector(descriptorClass, @selector(setSerialNum:))) &&
        (VSCGClassHasInstanceSelector(descriptorClass, @selector(setDispatchQueue:)) ||
         VSCGClassHasInstanceSelector(descriptorClass, @selector(setQueue:)));

    BOOL settingsAvailable =
        VSCGClassHasInstanceSelector(settingsClass, @selector(init)) &&
        VSCGClassHasInstanceSelector(settingsClass, @selector(setModes:)) &&
        VSCGClassHasInstanceSelector(settingsClass, @selector(setHiDPI:));

    BOOL modeAvailable =
        VSCGClassHasInstanceSelector(modeClass, @selector(initWithWidth:height:refreshRate:));

    BOOL displayAvailable =
        VSCGClassHasInstanceSelector(displayClass, @selector(initWithDescriptor:)) &&
        VSCGClassHasInstanceSelector(displayClass, @selector(applySettings:)) &&
        VSCGClassHasInstanceSelector(displayClass, @selector(displayID));

    return descriptorAvailable && settingsAvailable && modeAvailable && displayAvailable;
}

+ (nullable instancetype)createWithName:(NSString *)name
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                          serialNumber:(uint32_t)serialNumber
                              maxWidth:(uint32_t)maxWidth
                             maxHeight:(uint32_t)maxHeight
                                 modes:(NSArray<VSCGVirtualDisplayModeSpec *> *)modes
                   terminationHandler:(VSCGVirtualDisplayTerminationHandler)terminationHandler
                                 error:(NSError **)error {
    if (![self isAPIAvailable]) {
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorAPIUnavailable,
                                   @"The CGVirtualDisplay runtime API is unavailable.");
        }
        return nil;
    }

    if (name.length == 0 || modes.count == 0 || maxWidth == 0 || maxHeight == 0) {
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorInvalidConfiguration,
                                   @"The virtual display configuration is invalid.");
        }
        return nil;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    id descriptor = [[descriptorClass alloc] init];
    if (descriptor == nil) {
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorCreationFailed,
                                   @"Could not create a virtual display descriptor.");
        }
        return nil;
    }

    VSCGSendObject(descriptor, @selector(setName:), name);
    VSCGSendUInt32(descriptor, @selector(setVendorID:), vendorID);
    VSCGSendUInt32(descriptor, @selector(setProductID:), productID);
    VSCGSendUInt32(descriptor, @selector(setMaxPixelsWide:), maxWidth);
    VSCGSendUInt32(descriptor, @selector(setMaxPixelsHigh:), maxHeight);

    if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) {
        VSCGSendUInt32(descriptor, @selector(setSerialNumber:), serialNumber);
    }
    if ([descriptor respondsToSelector:@selector(setSerialNum:)]) {
        VSCGSendUInt32(descriptor, @selector(setSerialNum:), serialNumber);
    }

    if ([descriptor respondsToSelector:@selector(setSizeInMillimeters:)]) {
        VSCGSendSize(descriptor, @selector(setSizeInMillimeters:), CGSizeMake(600.0, 375.0));
    }
    if ([descriptor respondsToSelector:@selector(setRedPrimary:)]) {
        VSCGSendPoint(descriptor, @selector(setRedPrimary:), CGPointMake(0.6797, 0.3203));
        VSCGSendPoint(descriptor, @selector(setGreenPrimary:), CGPointMake(0.2559, 0.6983));
        VSCGSendPoint(descriptor, @selector(setBluePrimary:), CGPointMake(0.1494, 0.0557));
        VSCGSendPoint(descriptor, @selector(setWhitePoint:), CGPointMake(0.3127, 0.3290));
    }

    dispatch_queue_t callbackQueue = dispatch_queue_create("dev.narumi.DisplayLoom.termination", DISPATCH_QUEUE_SERIAL);
    if ([descriptor respondsToSelector:@selector(setDispatchQueue:)]) {
        VSCGSendObject(descriptor, @selector(setDispatchQueue:), callbackQueue);
    } else {
        VSCGSendObject(descriptor, @selector(setQueue:), callbackQueue);
    }

    VSCGTerminationState *terminationState = [VSCGTerminationState new];
    terminationState.handler = terminationHandler;
    void (^privateTerminationHandler)(id, id) = ^(__unused id display, __unused id terminationInfo) {
        [terminationState invoke];
    };
    VSCGSendObject(descriptor, @selector(setTerminationHandler:), privateTerminationHandler);

    NSMutableArray *privateModes = [NSMutableArray arrayWithCapacity:modes.count];
    for (VSCGVirtualDisplayModeSpec *mode in modes) {
        id privateMode = [(id<VSCGPrivateDisplayModeSelectors>)[modeClass alloc]
            initWithWidth:mode.width
                   height:mode.height
              refreshRate:mode.refreshRate];
        if (privateMode == nil) {
            [terminationState cancel];
            if (error != NULL) {
                *error = VSCGMakeError(VSCGVirtualDisplayErrorInvalidConfiguration,
                                       @"Could not create one of the requested display modes.");
            }
            return nil;
        }
        [privateModes addObject:privateMode];
    }

    id settings = [[settingsClass alloc] init];
    VSCGSendObject(settings, @selector(setModes:), privateModes);
    VSCGSendUInt32(settings, @selector(setHiDPI:), 0);

    id privateDisplay = [(id<VSCGPrivateDisplaySelectors>)[displayClass alloc]
        initWithDescriptor:descriptor];
    if (privateDisplay == nil) {
        [terminationState cancel];
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorCreationFailed,
                                   @"CoreGraphics refused to create the virtual display.");
        }
        return nil;
    }

    BOOL applied = ((BOOL (*)(id, SEL, id))objc_msgSend)(
        privateDisplay,
        @selector(applySettings:),
        settings
    );
    if (!applied) {
        [terminationState cancel];
        privateDisplay = nil;
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorSettingsRejected,
                                   @"CoreGraphics rejected the virtual display settings.");
        }
        return nil;
    }

    CGDirectDisplayID displayID = VSCGGetUInt32(privateDisplay, @selector(displayID));
    return [[self alloc] initWithPrivateDisplay:privateDisplay
                                     displayID:displayID
                              terminationState:terminationState];
}

- (instancetype)initWithPrivateDisplay:(id)privateDisplay
                              displayID:(CGDirectDisplayID)displayID
                       terminationState:(VSCGTerminationState *)terminationState {
    self = [super init];
    if (self != nil) {
        _privateDisplay = privateDisplay;
        _displayID = displayID;
        _terminationState = terminationState;
    }
    return self;
}

- (BOOL)isInvalidated {
    @synchronized (self) {
        return _privateDisplay == nil;
    }
}

- (BOOL)isValid {
    // Do not hold the state lock during a CoreGraphics call. Main-thread reads
    // must not wait for a mode write or the release of the private display.
    return !self.invalidated &&
           _displayID != kCGNullDirectDisplay &&
           CGDisplayIsOnline(_displayID);
}

- (BOOL)setModeWithWidth:(uint32_t)width
                  height:(uint32_t)height
             refreshRate:(double)refreshRate
                   error:(NSError **)error {
    CGDirectDisplayID displayID = self.displayID;
    if (!self.valid || !CGDisplayIsOnline(displayID)) {
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorInvalidated,
                                   @"The virtual display is no longer connected.");
        }
        return NO;
    }

    CFArrayRef copiedModes = CGDisplayCopyAllDisplayModes(displayID, NULL);
    if (copiedModes == NULL) {
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorModeUnavailable,
                                   @"Could not read the virtual display mode list.");
        }
        return NO;
    }

    NSArray *availableModes = CFBridgingRelease(copiedModes);
    CGDisplayModeRef selectedMode = NULL;
    for (id candidateObject in availableModes) {
        CGDisplayModeRef candidate = (__bridge CGDisplayModeRef)candidateObject;
        if (CGDisplayModeGetPixelWidth(candidate) != width ||
            CGDisplayModeGetPixelHeight(candidate) != height) {
            continue;
        }

        double candidateRefreshRate = CGDisplayModeGetRefreshRate(candidate);
        if (fabs(candidateRefreshRate - refreshRate) < 0.5) {
            selectedMode = candidate;
            break;
        }
    }

    // A zero reported rate cannot identify the requested rate when the same
    // resolution has multiple refresh rates. Do not silently choose a fallback.
    if (selectedMode == NULL) {
        if (error != NULL) {
            NSString *description = [NSString stringWithFormat:@"The %u × %u at %.0f Hz mode is unavailable.",
                                                               width, height, refreshRate];
            *error = VSCGMakeError(VSCGVirtualDisplayErrorModeUnavailable, description);
        }
        return NO;
    }

    // Recheck on the worker immediately before the write. An earlier UI check
    // can be stale after a queued mirror transaction.
    if (CGDisplayIsInMirrorSet(displayID)) {
        if (error != NULL) {
            *error = VSCGMakeError(VSCGVirtualDisplayErrorInvalidConfiguration,
                                   @"The display mode cannot change while mirroring.");
        }
        return NO;
    }

    CGError result = CGDisplaySetDisplayMode(displayID, selectedMode, NULL);
    if (result != kCGErrorSuccess) {
        if (error != NULL) {
            NSString *description = [NSString stringWithFormat:@"CoreGraphics could not switch display mode (error %d).",
                                                               result];
            *error = VSCGMakeError(VSCGVirtualDisplayErrorModeSwitchFailed, description);
        }
        return NO;
    }

    return YES;
}

- (void)invalidate {
    // Keep the last release outside the state lock. displayID stays immutable.
    __attribute__((objc_precise_lifetime)) id privateDisplay = nil;
    @synchronized (self) {
        [_terminationState cancel];
        privateDisplay = _privateDisplay;
        _privateDisplay = nil;
    }
    (void)privateDisplay;
}

- (void)dealloc {
    [self invalidate];
}

@end
