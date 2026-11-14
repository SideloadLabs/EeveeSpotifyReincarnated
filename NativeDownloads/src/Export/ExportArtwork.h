#pragma once
#import <Foundation/Foundation.h>
NSString *SAPExportAlbumCoverURI(NSArray *albumFields);
NSString *SAPExportAlbumURI(NSArray *albumFields);
// The callback runs on the main queue; cancellation suppresses late results.
dispatch_block_t SAPLoadExportArtwork(NSString *uri,void (^completion)(NSDictionary *artwork));
// Artwork lives with the exported URL object, only for the share operation.
void SAPAttachExportArtwork(NSURL *file,NSDictionary *artwork);
NSDictionary *SAPAttachedExportArtwork(NSURL *file);
// Returns file item sources with native share-sheet previews; never extra JPEG attachments.
NSArray *SAPAudioExportShareItems(NSArray<NSURL *> *files);

NSString *SAPExportArtistName(NSArray *fields,unsigned field);

void SAPPrepareAudioExportShareItems(NSArray<NSURL *> *files,BOOL album,void (^completion)(NSArray *,NSString *));
