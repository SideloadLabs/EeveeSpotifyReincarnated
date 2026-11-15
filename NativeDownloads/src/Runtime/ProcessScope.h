#pragma once
#import <Foundation/Foundation.h>

// App extensions run in their own process. They must not install the host
// app's audio, network, manager or settings hooks if a signer injects Pixie.
static inline BOOL SAPIsAppExtensionProcess(NSDictionary *info, NSString *bundlePath) {
    return info[@"NSExtension"] != nil ||
        [bundlePath.pathExtension.lowercaseString isEqualToString:@"appex"];
}
