#import <Foundation/Foundation.h>

@interface SPTLinkDispatcherImplementation : NSObject
- (BOOL)navigateToInternalURI:(NSURL *)uri options:(long long)options reason:(id)reason resultHandler:(id)resultHandler;
@end
