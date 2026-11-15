#pragma once
#import <Foundation/Foundation.h>
// Transfers a native share completion to the file sheet; delivers once on every terminal path.
@interface SAPShareCompletionRelay:NSObject
- (instancetype)initWithCompletion:(void (^)(NSString *,BOOL,NSArray *,NSError *))completion;
- (void)finish:(NSString *)type completed:(BOOL)completed items:(NSArray *)items error:(NSError *)error;
@end
