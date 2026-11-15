#pragma once
#import <Foundation/Foundation.h>
// Export selected verified offline tracks using the current Pixie format, then
// package them. Partial failures are returned explicitly; no source is deleted.
NSProgress *SAPExportOfflineLibrarySelection(NSArray<NSDictionary *> *tracks,BOOL zip,
    void (^progress)(NSUInteger completed,NSUInteger total,NSString *message),
    void (^completion)(NSURL *package,NSArray<NSDictionary *> *failures,NSString *error));
// Structured main-queue events: preparing/prepared (URI), packaging (fraction),
// ready/failed/cancelled. Track completion and package progress are separate phases.
NSProgress *SAPExportOfflineLibrarySelectionWithEvents(NSArray<NSDictionary *> *tracks,BOOL zip,
    void (^event)(NSDictionary *event),
    void (^completion)(NSURL *package,NSArray<NSDictionary *> *failures,NSString *error));

// Main-queue append to an active job; includes queued/completed/failed URI dedup.
// Reuses its format and Folder/ZIP choice. Returns the number accepted; zero
// for unknown, finished or cancelled operations. Restarts packaging only.
NSUInteger SAPAppendOfflineLibrarySelection(NSProgress *operation,NSArray<NSDictionary *> *tracks);
