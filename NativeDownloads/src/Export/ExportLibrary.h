#pragma once
#import <Foundation/Foundation.h>
// Thread-safe library operations. Published files are keyed by Spotify track URI and format.
NSURL *SAPExportLibraryPublish(NSURL *source,NSURL *root,NSDictionary *track,NSString **error);
NSURL *SAPExportLibraryExisting(NSURL *root,NSDictionary *track,NSString *format);
BOOL SAPExportLibraryClear(NSURL *root,NSString **error);
