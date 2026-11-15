#pragma once
#import <Foundation/Foundation.h>

// Returns the album and every disc/track in Spotify's metadata order.
// The callback runs on the main queue. No account token or key is persisted.
void SAPFetchExportAlbumMetadata(NSString *albumURI,
                            void (^completion)(NSDictionary *album, NSString *error));

// Pure protobuf parser, also used by host tests. Tracks with only a valid gid
// retain their URI and position with metadata_complete == NO for later lookup.
NSDictionary *SAPParseExportAlbumMetadata(NSData *response, NSString *albumURI);
