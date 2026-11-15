#pragma once
#import <Foundation/Foundation.h>
// Writes one track's complete, validated Ogg (named after the track) into
// folder from the native cache. failure is a user-facing reason; evidence holds
// the failure stage for the support report. cancelled may be nil.
BOOL SAPExportTrackFromCache(NSDictionary *track, NSURL *folder, NSUInteger number, NSURL **result,
                             NSString **failure, NSDictionary **evidence, BOOL (^cancelled)(void));
// An existing export of track in format ("ogg" or "m4a") that can be reused as is.
BOOL SAPExportValidExistingAudio(NSURL *file, NSDictionary *track, NSString *format, BOOL (^cancelled)(void));
// Embeds track[@"export_artwork"] into an Ogg file in place. Skipped (NO) for an
// intermediate Ogg that is converted to M4A next (deferred), which tags AAC itself.
BOOL SAPExportEmbedArtwork(NSURL *url, NSDictionary *track, NSString *format, BOOL deferred, BOOL (^cancelled)(void));
// Artwork, share filename and encoding metadata handed to the share/M4A stages.
NSDictionary *SAPExportShareMetadata(NSDictionary *track, NSURL *file);
