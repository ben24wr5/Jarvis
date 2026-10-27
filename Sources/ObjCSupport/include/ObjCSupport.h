#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a block and turns any Objective-C exception (e.g. AVAudioEngine's
/// "required condition is false") into a normal error instead of a crash.
@interface OLEDSafe : NSObject
+ (BOOL)run:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
