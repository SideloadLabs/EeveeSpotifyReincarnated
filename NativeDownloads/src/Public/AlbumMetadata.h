#pragma once
#import <Foundation/Foundation.h>

// Returns the album and every disc/track in Spotify's metadata order.
// The callback runs on the main queue. No account token or key is persisted.
void SAPFetchAlbumMetadata(NSString *albumURI,
                            void (^completion)(NSDictionary *album, NSString *error));

// Pure protobuf parser, also used by host tests.
NSDictionary *SAPParseAlbumMetadata(NSData *response, NSString *albumURI);
