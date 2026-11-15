#pragma once
#import <Foundation/Foundation.h>

// Spotify's image-loader registry uses these CDN formats. Mosaic presets
// include 300 px; requesting an arbitrary 128 px tile returns HTTP 404.
static inline NSString *SAPPlaylistArtworkURL(NSString *uri) {
    if(![uri isKindOfClass:NSString.class])return @"";
    BOOL mosaic=[uri hasPrefix:@"spotify:mosaic:"];
    NSString *prefix=mosaic?@"spotify:mosaic:":@"spotify:image:";
    if(![uri hasPrefix:prefix])return @"";
    NSArray *parts=[[uri substringFromIndex:prefix.length]componentsSeparatedByString:@":"];
    if(parts.count<1 || parts.count>(mosaic?4:1))return @"";
    NSCharacterSet *bad=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    for(NSString *part in parts)if(part.length!=40 || [part rangeOfCharacterFromSet:bad].location!=NSNotFound)return @"";
    NSString *ids=[[parts componentsJoinedByString:@""]lowercaseString];
    return [(mosaic?@"https://mosaic.scdn.co/300/":@"https://i.scdn.co/image/")stringByAppendingString:ids];
}
