#pragma once
#import <Foundation/Foundation.h>

// Pixie's interface is English-only, regardless of Spotify's preferred language.
// Keep the paired-string API compatible with existing callers.
NSString *SAPL(NSString *russian,NSString *english);
