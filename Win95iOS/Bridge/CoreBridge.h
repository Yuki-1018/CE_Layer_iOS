#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@interface Win95VideoFrame : NSObject
@property(nonatomic, readonly) NSData *data;
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) NSInteger bytesPerRow;
@property(nonatomic, readonly) double aspectRatio;
@property(nonatomic, readonly) uint64_t generation;
@end

typedef void (^Win95Completion)(NSError * _Nullable error);

@interface Win95CoreBridge : NSObject

@property(atomic, readonly, getter=isRunning) BOOL running;
@property(atomic, readonly, getter=isPaused) BOOL paused;
@property(nonatomic, copy, nullable) void (^statusHandler)(NSString *status);

- (instancetype)initWithSaveDirectory:(NSURL *)saveDirectory
                       systemDirectory:(NSURL *)systemDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)startWithDiskURL:(NSURL *)diskURL
                   CDURL:(NSURL * _Nullable)CDURL
              completion:(Win95Completion)completion NS_SWIFT_NAME(start(diskURL:cdURL:completion:));
- (void)stopWithCompletion:(dispatch_block_t _Nullable)completion;
- (void)setEmulationPaused:(BOOL)paused;
- (void)reset;
- (void)flushDisk;
- (void)flushDiskWithCompletion:(Win95Completion)completion NS_SWIFT_NAME(flushDisk(completion:));

- (void)saveSuspendStateToURL:(NSURL *)url completion:(Win95Completion)completion NS_SWIFT_NAME(saveSuspendState(to:completion:));
- (void)loadSuspendStateFromURL:(NSURL *)url completion:(Win95Completion)completion NS_SWIFT_NAME(loadSuspendState(from:completion:));

- (nullable Win95VideoFrame *)latestVideoFrameAfterGeneration:(uint64_t)generation;
- (NSUInteger)readAudioFrames:(int16_t *)buffer maxFrames:(NSUInteger)maxFrames;

- (void)sendKey:(unsigned)keyCode pressed:(BOOL)pressed;
- (void)addMouseDeltaX:(NSInteger)deltaX deltaY:(NSInteger)deltaY;
- (void)addMouseWheelDelta:(NSInteger)delta;
- (void)setLeftMouseButton:(BOOL)pressed;
- (void)setRightMouseButton:(BOOL)pressed;

@end

NS_ASSUME_NONNULL_END
