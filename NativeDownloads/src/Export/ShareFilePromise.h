#pragma once
#import <Foundation/Foundation.h>
@interface SAPShareFilePromise:NSObject
- (NSProgress *)load:(void(^)(NSURL *file,NSError *error))completion;
- (void)resolveFile:(NSURL *)file error:(NSError *)error;
- (void)cancel;
@property(nonatomic,readonly,strong) NSURL *resolvedFile;
@end
