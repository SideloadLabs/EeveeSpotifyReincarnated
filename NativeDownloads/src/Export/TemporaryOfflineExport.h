#pragma once
#import <Foundation/Foundation.h>
// Capture before creating any native temporary download. Unknown or incomplete
// baseline replies fail closed. Token is opaque, in-memory, and reusable only
// for idempotent cleanup of this same preparation job.
void SAPCaptureTemporaryOfflineExport(NSString *targetURI,NSArray<NSDictionary *> *resolvedTracks,
    void (^completion)(NSDictionary *token,NSString *error));
// Accepted means exact AddDownload success for at least one track. An album is
// prepared and removed track by track; only tracks that were absent at capture
// are removed. A queued request also requires cleanup when cancellation
// precedes its first visible state.
// False never authorizes any removal.
void SAPCleanupTemporaryOfflineExport(NSDictionary *token,BOOL ourDownloadAccepted,
    void (^completion)(NSString *error));
