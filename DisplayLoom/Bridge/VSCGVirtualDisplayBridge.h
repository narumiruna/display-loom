#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const VSCGVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(VSCGVirtualDisplayErrorDomain, VSCGVirtualDisplayErrorCode) {
    VSCGVirtualDisplayErrorAPIUnavailable = 1,
    VSCGVirtualDisplayErrorInvalidConfiguration = 2,
    VSCGVirtualDisplayErrorCreationFailed = 3,
    VSCGVirtualDisplayErrorSettingsRejected = 4,
    VSCGVirtualDisplayErrorRegistrationTimedOut = 5,
    VSCGVirtualDisplayErrorModeUnavailable = 6,
    VSCGVirtualDisplayErrorModeSwitchFailed = 7,
    VSCGVirtualDisplayErrorInvalidated = 8,
};

@interface VSCGVirtualDisplayModeSpec : NSObject

@property(nonatomic, readonly) uint32_t width;
@property(nonatomic, readonly) uint32_t height;
@property(nonatomic, readonly) double refreshRate;

- (instancetype)initWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  refreshRate:(double)refreshRate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

typedef void (^VSCGVirtualDisplayTerminationHandler)(void);

@interface VSCGVirtualDisplayHandle : NSObject

@property(class, nonatomic, readonly, getter=isAPIAvailable) BOOL APIAvailable;
// Stable for the lifetime of this handle, including after invalidation.
@property(nonatomic, readonly) CGDirectDisplayID displayID;
// These reads are safe from the main thread during worker operations.
@property(nonatomic, readonly, getter=isValid) BOOL valid;
@property(nonatomic, readonly, getter=isInvalidated) BOOL invalidated;

// Returns a pending handle without waiting for registration or selecting a mode.
// The caller owns it until registration succeeds or invalidate is called.
// Create, mode writes, and invalidation must use the shared serial display worker.
+ (nullable instancetype)createWithName:(NSString *)name
                              vendorID:(uint32_t)vendorID
                             productID:(uint32_t)productID
                          serialNumber:(uint32_t)serialNumber
                              maxWidth:(uint32_t)maxWidth
                             maxHeight:(uint32_t)maxHeight
                                 modes:(NSArray<VSCGVirtualDisplayModeSpec *> *)modes
                   terminationHandler:(VSCGVirtualDisplayTerminationHandler)terminationHandler
                                 error:(NSError **)error;

- (BOOL)setModeWithWidth:(uint32_t)width
                  height:(uint32_t)height
             refreshRate:(double)refreshRate
                   error:(NSError **)error
    NS_SWIFT_NAME(setMode(width:height:refreshRate:));

- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
