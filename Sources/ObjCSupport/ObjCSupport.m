#import "ObjCSupport.h"

@implementation OLEDSafe

+ (BOOL)run:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"OLED"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}

@end
