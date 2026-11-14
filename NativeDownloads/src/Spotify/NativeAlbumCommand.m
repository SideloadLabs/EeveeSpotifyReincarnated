#import "NativeAlbumCommand.h"
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL exactURI(id value,NSString *kind) {
    if(![value isKindOfClass:NSString.class])return NO;
    NSString *prefix=[NSString stringWithFormat:@"spotify:%@:",kind];NSString *uri=value;
    if(![uri hasPrefix:prefix] || uri.length!=prefix.length+22)return NO;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    return [[uri substringFromIndex:prefix.length]rangeOfCharacterFromSet:invalid].location==NSNotFound;
}
BOOL SAPInvokeNativeAlbumCommand(id manager,NSString *albumURI,NSArray<NSString *> *trackURIs,NSString **reason) {
    if(!NSThread.isMainThread) {if(reason)*reason=@"The native album action must run on the main thread.";return NO;}
    if(!exactURI(albumURI,@"album") || ![trackURIs isKindOfClass:NSArray.class] || !trackURIs.count || trackURIs.count>4096) {
        if(reason)*reason=@"A verified album and its complete track list are required.";return NO;
    }
    NSMutableArray *urls=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSString *uri in trackURIs) {
        if(!exactURI(uri,@"track")) {if(reason)*reason=@"Album metadata contained an invalid track identity.";return NO;}
        if(![seen containsObject:uri]) {[seen addObject:uri];[urls addObject:[NSURL URLWithString:uri]];}
    }
    SEL selector=NSSelectorFromString(@"makeEntityAvailableOfflineWithURL:trackURLs:");
    Method method=class_getInstanceMethod(object_getClass(manager),selector);char type[16]={0};
    if(!method || method_getNumberOfArguments(method)!=4) {if(reason)*reason=@"Spotify's native album download handler is unavailable.";return NO;}
    method_getReturnType(method,type,sizeof(type));BOOL valid=type[0]=='v';
    for(unsigned i=2;i<4;i++) {method_getArgumentType(method,i,type,sizeof(type));valid=valid && type[0]=='@';}
    if(!valid) {if(reason)*reason=@"Spotify's native album handler signature does not match.";return NO;}
    @try {
        // Dispatch through the current implementation, preserving other mods'
        // hooks and Spotify's own scheduler/context registration behavior.
        ((void(*)(id,SEL,id,id))objc_msgSend)(manager,selector,[NSURL URLWithString:albumURI],[urls copy]);
    }@catch(NSException *exception) {
        if(reason)*reason=[NSString stringWithFormat:@"The native handler raised %@. Its result is unconfirmed; the command was not retried.",exception.name];return NO;
    }
    return YES;
}
