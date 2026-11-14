#pragma once
#import <Foundation/Foundation.h>
// The returned URL owns a temporary folder lease. Files are hard links, never audio copies.
NSURL *SAPCreateAudioShareFolder(NSArray<NSURL *> *files,NSString *albumName,NSString **error);

// Share-only audio URLs retain their scratch directory until all consumers release them.
void SAPRetainTemporaryAudioFiles(NSArray<NSURL *> *files,NSURL *scratchRoot);

// A single named hard-link snapshot, retaining its private folder lease.
NSURL *SAPCreateAudioShareFile(NSURL *file,NSString **error);
