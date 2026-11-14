#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Prepared M4A/Ogg files in app temporary storage or Documents/Pixie Exports.
// Required: file (file NSURL), uri (track identity).
// Optional: name, artist_name, album_name, artist_uri, album_uri, number, disc, category.
// Artist/release grouping uses entity URIs when present, otherwise display names.
// All callbacks run on main. Cancel the returned progress to cancel all work.
// Folder snapshots use hard links; ZIP stores the exact audio bytes without recompression.
// The returned URL owns its private scratch lease until that URL is released. A consumer
// must retain this exact URL until its share operation completes, then release it or call
// SAPReleaseOfflineLibraryPackage. Input files and their parents are never removed.
FOUNDATION_EXPORT NSProgress *SAPPrepareOfflineLibraryPackage(
    NSArray<NSDictionary *> *tracks, BOOL zip,
    void (^ _Nullable progress)(double fraction),
    void (^completion)(NSURL * _Nullable package, NSError * _Nullable error));
FOUNDATION_EXPORT void SAPReleaseOfflineLibraryPackage(NSURL *package);
NS_ASSUME_NONNULL_END
